library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng is
  generic (
    MAX_NODES  : natural := 40;
    DATA_WORDS : natural := 100;

    INIT_X0    : integer := 200;
    INIT_Y0    : integer := 200;
    INIT_X1    : integer := 800;
    INIT_Y1    : integer := 800;

    CLOCK_HZ     : natural := 27_000_000;
    DBG_DELAY_MS : natural := 100;

    -- error scaling: err += (best_d2 >> ERR_SHIFT)
    ERR_SHIFT : natural := 4
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;
    start_i : in  std_logic;

    -- dataset stream (word32: x16|y16)  x in [15:0], y in [31:16]
    data_raddr_o : out unsigned(6 downto 0);
    data_rdata_i : in  std_logic_vector(31 downto 0);

    -- status
    gng_busy_o : out std_logic;
    gng_done_o : out std_logic;

    -- UART TX handshake (uart_tx instance tetap di TOP)
    tx_busy_i  : in  std_logic;
    tx_done_i  : in  std_logic;
    tx_start_o : out std_logic;
    tx_data_o  : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of gng is

  ---------------------------------------------------------------------------
  -- Types
  ---------------------------------------------------------------------------
  subtype s16 is signed(15 downto 0);
  subtype u8  is unsigned(7 downto 0);
  subtype u32 is unsigned(31 downto 0);

  ---------------------------------------------------------------------------
  -- Winner epsilon = 0.3 (Q8)
  -- eps_q8 = round(0.3 * 256) = 77
  -- delta = (dx * eps_q8) >> 8
  ---------------------------------------------------------------------------
  constant EPS_WIN_Q8   : integer := 77;
  constant EPS_WIN_SH   : natural := 8;
  constant EPS_Q8_S9    : signed(8 downto 0) := to_signed(EPS_WIN_Q8, 9); -- 9-bit

  ---------------------------------------------------------------------------
  -- Node packing in BRAM (80-bit)
  -- [15:0]   x (s16)
  -- [31:16]  y (s16)
  -- [32]     active (1)
  -- [40:33]  degree (u8)
  -- [72:41]  error (u32)
  -- [79:73]  padding
  ---------------------------------------------------------------------------
  constant NODE_W : natural := 80;

  constant X_L   : natural := 0;
  constant X_H   : natural := 15;
  constant Y_L   : natural := 16;
  constant Y_H   : natural := 31;
  constant ACT_B : natural := 32;
  constant DEG_L : natural := 33;
  constant DEG_H : natural := 40;
  constant ERR_L : natural := 41;
  constant ERR_H : natural := 72;

  function pack_node(x : s16; y : s16; act : std_logic; deg : u8; err : u32)
    return std_logic_vector is
    variable w : std_logic_vector(NODE_W-1 downto 0) := (others => '0');
  begin
    w(X_H downto X_L) := std_logic_vector(x);
    w(Y_H downto Y_L) := std_logic_vector(y);
    w(ACT_B)          := act;
    w(DEG_H downto DEG_L) := std_logic_vector(deg);
    w(ERR_H downto ERR_L) := std_logic_vector(err);
    return w;
  end function;

  function get_x(w : std_logic_vector) return s16 is
  begin
    return signed(w(X_H downto X_L));
  end function;

  function get_y(w : std_logic_vector) return s16 is
  begin
    return signed(w(Y_H downto Y_L));
  end function;

  function get_act(w : std_logic_vector) return std_logic is
  begin
    return w(ACT_B);
  end function;

  function get_deg(w : std_logic_vector) return u8 is
  begin
    return unsigned(w(DEG_H downto DEG_L));
  end function;

  function get_err(w : std_logic_vector) return u32 is
  begin
    return unsigned(w(ERR_H downto ERR_L));
  end function;

  ---------------------------------------------------------------------------
  -- Saturate helper
  ---------------------------------------------------------------------------
  function sat_s16(v : signed) return s16 is
    variable vi : integer;
  begin
    vi := to_integer(v);
    if vi > 32767 then
      return to_signed(32767, 16);
    elsif vi < -32768 then
      return to_signed(-32768, 16);
    else
      return to_signed(vi, 16);
    end if;
  end function;

  ---------------------------------------------------------------------------
  -- Edge memory: upper triangle 1D (age 8-bit)
  ---------------------------------------------------------------------------
  constant EDGE_N : natural := (MAX_NODES * (MAX_NODES - 1)) / 2;

  function edge_base(i : natural; N : natural) return natural is
  begin
    return (i * (2*N - i - 1)) / 2;
  end function;

  function edge_idx(i : natural; j : natural; N : natural) return natural is
  begin
    -- assume i < j
    return edge_base(i, N) + (j - i - 1);
  end function;

  ---------------------------------------------------------------------------
  -- Force BRAM (Gowin)
  ---------------------------------------------------------------------------
  attribute syn_ramstyle : string;

  type node_mem_t is array (0 to MAX_NODES-1) of std_logic_vector(NODE_W-1 downto 0);
  signal node_mem : node_mem_t;
  attribute syn_ramstyle of node_mem : signal is "block_ram";

  type edge_mem_t is array (0 to EDGE_N-1) of std_logic_vector(7 downto 0);
  signal edge_mem : edge_mem_t;
  attribute syn_ramstyle of edge_mem : signal is "block_ram";

  ---------------------------------------------------------------------------
  -- Node BRAM ports (1R1W)
  ---------------------------------------------------------------------------
  signal node_raddr : unsigned(7 downto 0) := (others => '0');
  signal node_rdata : std_logic_vector(NODE_W-1 downto 0) := (others => '0');

  signal node_we    : std_logic := '0';
  signal node_waddr : unsigned(7 downto 0) := (others => '0');
  signal node_wdata : std_logic_vector(NODE_W-1 downto 0) := (others => '0');

  ---------------------------------------------------------------------------
  -- Edge BRAM ports (1R1W)
  ---------------------------------------------------------------------------
  signal edge_raddr : unsigned(12 downto 0) := (others => '0');
  signal edge_rdata : std_logic_vector(7 downto 0) := (others => '0');

  signal edge_we    : std_logic := '0';
  signal edge_waddr : unsigned(12 downto 0) := (others => '0');
  signal edge_wdata : std_logic_vector(7 downto 0) := (others => '0');

  ---------------------------------------------------------------------------
  -- Dataset sample latch
  ---------------------------------------------------------------------------
  signal data_addr : unsigned(6 downto 0) := (others => '0');
  signal sample_x  : s16 := (others => '0');
  signal sample_y  : s16 := (others => '0');

  ---------------------------------------------------------------------------
  -- Phase controller
  ---------------------------------------------------------------------------
  type phase_t is (
    P_IDLE,

    -- INIT
    P_INIT_CLR_NODE,
    P_INIT_CLR_EDGE,
    P_INIT_SEED0,
    P_INIT_SEED1,
    P_INIT_SEED_EDGE0, -- write edge01 + node0 degree=1
    P_INIT_SEED_EDGE1, -- write node1 degree=1

    -- loop
    P_WAIT_100MS,
    P_SAMPLE_REQ,
    P_SAMPLE_WAIT,

    -- winner scan
    P_WIN_SETUP,
    P_WIN_REQ,
    P_WIN_WAIT,
    P_WIN_EVAL,

    -- error + move s1 (RMW)
    P_UPD_RD,
    P_UPD_WAIT,
    P_UPD_WR,

    -- debug UART (also reads edge01 to keep BRAM used)
    P_DBG_EDGE_REQ,
    P_DBG_EDGE_WAIT,
    P_TX_PREP,
    P_TX_SEND,
    P_TX_WAIT,
    P_NEXT
  );
  signal ph : phase_t := P_IDLE;

  signal started : std_logic := '0';

  -- init counters
  signal init_n : natural range 0 to MAX_NODES-1 := 0;
  signal init_e : natural range 0 to EDGE_N-1 := 0;

  -- sample index
  signal samp_i : natural range 0 to DATA_WORDS-1 := 0;

  -- 100ms delay counter
  constant DELAY_TICKS : natural := (CLOCK_HZ/1000) * DBG_DELAY_MS;
  signal delay_cnt : integer range 0 to integer(DELAY_TICKS) := 0;

  -- winner scan regs
  signal scan_i : natural range 0 to MAX_NODES := 0;

  signal best_id    : unsigned(7 downto 0) := (others => '0');
  signal second_id  : unsigned(7 downto 0) := (others => '0');
  signal best_d2    : unsigned(34 downto 0) := (others => '1');
  signal second_d2  : unsigned(34 downto 0) := (others => '1');

  signal s1_id : unsigned(7 downto 0) := (others => '0');
  signal s2_id : unsigned(7 downto 0) := (others => '0');

  -- done pulse each loop
  signal done_p : std_logic := '0';

  -- debug: last updated error(s1)
  signal dbg_err32 : u32 := (others => '0');

  -- NEW debug: last s1 position after update
  signal dbg_s1_x : s16 := (others => '0');
  signal dbg_s1_y : s16 := (others => '0');

  -- UART TX helper
  signal tx_inflight : std_logic := '0';
  signal tx_idx      : natural range 0 to 31 := 0;
  signal tx_len      : natural range 0 to 32 := 0;

  type tx_buf_t is array (0 to 31) of std_logic_vector(7 downto 0);
  signal tx_buf : tx_buf_t := (others => (others => '0'));

  -- debug tags
  constant B_A5 : std_logic_vector(7 downto 0) := x"A5";
  constant B_A6 : std_logic_vector(7 downto 0) := x"A6";
  constant B_A7 : std_logic_vector(7 downto 0) := x"A7";
  constant B_A8 : std_logic_vector(7 downto 0) := x"A8";
  constant B_A9 : std_logic_vector(7 downto 0) := x"A9";
  constant B_AA : std_logic_vector(7 downto 0) := x"AA";
  constant B_AB : std_logic_vector(7 downto 0) := x"AB";
  constant B_AC : std_logic_vector(7 downto 0) := x"AC";
  constant B_AD : std_logic_vector(7 downto 0) := x"AD";

  -- NEW tags for s1 position
  constant B_AE : std_logic_vector(7 downto 0) := x"AE"; -- s1_x lo
  constant B_AF : std_logic_vector(7 downto 0) := x"AF"; -- s1_x hi
  constant B_B0 : std_logic_vector(7 downto 0) := x"B0"; -- s1_y lo
  constant B_B2 : std_logic_vector(7 downto 0) := x"B2"; -- s1_y hi

begin

  ---------------------------------------------------------------------------
  -- Outputs
  ---------------------------------------------------------------------------
  data_raddr_o <= data_addr;
  gng_busy_o   <= started;
  gng_done_o   <= done_p;

  ---------------------------------------------------------------------------
  -- Node BRAM (1R1W)
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      node_rdata <= node_mem(to_integer(node_raddr));
      if node_we = '1' then
        node_mem(to_integer(node_waddr)) <= node_wdata;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Edge BRAM (1R1W)
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      edge_rdata <= edge_mem(to_integer(edge_raddr));
      if edge_we = '1' then
        edge_mem(to_integer(edge_waddr)) <= edge_wdata;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Single phase controller
  ---------------------------------------------------------------------------
  process(clk_i)
    variable dx_s : signed(16 downto 0);
    variable dy_s : signed(16 downto 0);
    variable dx2  : unsigned(33 downto 0);
    variable dy2  : unsigned(33 downto 0);
    variable d2   : unsigned(34 downto 0);

    variable w    : std_logic_vector(NODE_W-1 downto 0);
    variable act  : std_logic;
    variable deg  : u8;
    variable nx   : s16;
    variable ny   : s16;

    variable cur_err : u32;
    variable add_err : u32;
    variable new_err : u32;

    -- move s1 (FIXED widths: dx(17) * eps(9) -> 26 bits)
    variable mulx  : signed(25 downto 0);  -- 26-bit
    variable muly  : signed(25 downto 0);  -- 26-bit
    variable delx  : signed(16 downto 0);  -- 17-bit
    variable dely  : signed(16 downto 0);  -- 17-bit
    variable nx_new : signed(17 downto 0);
    variable ny_new : signed(17 downto 0);

    constant D2_INF : unsigned(34 downto 0) := (others => '1');
    variable idx01 : natural;

    variable sx : s16;
    variable sy : s16;
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        ph <= P_IDLE;
        started <= '0';

        node_we <= '0';
        edge_we <= '0';

        data_addr <= (others => '0');
        sample_x  <= (others => '0');
        sample_y  <= (others => '0');

        init_n <= 0;
        init_e <= 0;

        samp_i <= 0;
        delay_cnt <= 0;

        scan_i <= 0;
        best_id <= (others => '0');
        second_id <= (others => '0');
        best_d2 <= D2_INF;
        second_d2 <= D2_INF;
        s1_id <= (others => '0');
        s2_id <= (others => '0');

        dbg_err32 <= (others => '0');
        dbg_s1_x  <= (others => '0');
        dbg_s1_y  <= (others => '0');

        done_p <= '0';

        tx_start_o <= '0';
        tx_data_o  <= (others => '0');
        tx_inflight <= '0';
        tx_idx <= 0;
        tx_len <= 0;

      else
        -- defaults
        node_we <= '0';
        edge_we <= '0';
        done_p  <= '0';

        tx_start_o <= '0';

        -- clear inflight robustly
        if tx_inflight = '1' then
          if (tx_done_i = '1') or (tx_busy_i = '0') then
            tx_inflight <= '0';
          end if;
        end if;

        case ph is

          -------------------------------------------------------------------
          -- IDLE
          -------------------------------------------------------------------
          when P_IDLE =>
            started <= '0';
            if start_i = '1' then
              started <= '1';
              init_n <= 0;
              ph <= P_INIT_CLR_NODE;
            end if;

          -------------------------------------------------------------------
          -- INIT: clear node mem
          -------------------------------------------------------------------
          when P_INIT_CLR_NODE =>
            node_we    <= '1';
            node_waddr <= to_unsigned(init_n, 8);
            node_wdata <= (others => '0');

            if init_n = MAX_NODES-1 then
              init_e <= 0;
              ph <= P_INIT_CLR_EDGE;
            else
              init_n <= init_n + 1;
            end if;

          -------------------------------------------------------------------
          -- INIT: clear edge mem
          -------------------------------------------------------------------
          when P_INIT_CLR_EDGE =>
            edge_we    <= '1';
            edge_waddr <= to_unsigned(init_e, 13);
            edge_wdata <= (others => '0');

            if init_e = EDGE_N-1 then
              ph <= P_INIT_SEED0;
            else
              init_e <= init_e + 1;
            end if;

          -------------------------------------------------------------------
          -- seed node0
          -------------------------------------------------------------------
          when P_INIT_SEED0 =>
            node_we    <= '1';
            node_waddr <= to_unsigned(0, 8);
            node_wdata <= pack_node(
                            to_signed(INIT_X0, 16),
                            to_signed(INIT_Y0, 16),
                            '1',
                            to_unsigned(0,8),
                            (others => '0')
                          );
            ph <= P_INIT_SEED1;

          -------------------------------------------------------------------
          -- seed node1
          -------------------------------------------------------------------
          when P_INIT_SEED1 =>
            node_we    <= '1';
            node_waddr <= to_unsigned(1, 8);
            node_wdata <= pack_node(
                            to_signed(INIT_X1, 16),
                            to_signed(INIT_Y1, 16),
                            '1',
                            to_unsigned(0,8),
                            (others => '0')
                          );
            ph <= P_INIT_SEED_EDGE0;

          -------------------------------------------------------------------
          -- write edge(0,1)=1 AND set node0 degree=1
          -------------------------------------------------------------------
          when P_INIT_SEED_EDGE0 =>
            idx01 := edge_idx(0, 1, MAX_NODES);

            edge_we    <= '1';
            edge_waddr <= to_unsigned(idx01, 13);
            edge_wdata <= std_logic_vector(to_unsigned(1, 8));

            node_we    <= '1';
            node_waddr <= to_unsigned(0, 8);
            node_wdata <= pack_node(
                            to_signed(INIT_X0, 16),
                            to_signed(INIT_Y0, 16),
                            '1',
                            to_unsigned(1,8),
                            (others => '0')
                          );

            ph <= P_INIT_SEED_EDGE1;

          -------------------------------------------------------------------
          -- set node1 degree=1
          -------------------------------------------------------------------
          when P_INIT_SEED_EDGE1 =>
            node_we    <= '1';
            node_waddr <= to_unsigned(1, 8);
            node_wdata <= pack_node(
                            to_signed(INIT_X1, 16),
                            to_signed(INIT_Y1, 16),
                            '1',
                            to_unsigned(1,8),
                            (others => '0')
                          );

            samp_i <= 0;
            delay_cnt <= integer(DELAY_TICKS);
            ph <= P_WAIT_100MS;

          -------------------------------------------------------------------
          -- Delay between loops
          -------------------------------------------------------------------
          when P_WAIT_100MS =>
            if delay_cnt <= 0 then
              ph <= P_SAMPLE_REQ;
            else
              delay_cnt <= delay_cnt - 1;
            end if;

          -------------------------------------------------------------------
          -- Sample read (1-cycle latency)
          -------------------------------------------------------------------
          when P_SAMPLE_REQ =>
            data_addr <= to_unsigned(samp_i, 7);
            ph <= P_SAMPLE_WAIT;

          when P_SAMPLE_WAIT =>
            sample_x <= signed(data_rdata_i(15 downto 0));
            sample_y <= signed(data_rdata_i(31 downto 16));
            ph <= P_WIN_SETUP;

          -------------------------------------------------------------------
          -- Winner scan setup
          -------------------------------------------------------------------
          when P_WIN_SETUP =>
            best_d2   <= D2_INF;
            second_d2 <= D2_INF;
            best_id   <= (others => '0');
            second_id <= (others => '0');

            scan_i <= 0;
            ph <= P_WIN_REQ;

          -------------------------------------------------------------------
          -- Request node read
          -------------------------------------------------------------------
          when P_WIN_REQ =>
            node_raddr <= to_unsigned(scan_i, 8);
            ph <= P_WIN_WAIT;

          when P_WIN_WAIT =>
            ph <= P_WIN_EVAL;

          -------------------------------------------------------------------
          -- Evaluate node_i
          -------------------------------------------------------------------
          when P_WIN_EVAL =>
            w   := node_rdata;
            act := get_act(w);

            if act = '1' then
              nx := get_x(w);
              ny := get_y(w);

              dx_s := resize(sample_x, 17) - resize(nx, 17);
              dy_s := resize(sample_y, 17) - resize(ny, 17);

              dx2 := unsigned(resize(dx_s*dx_s, 34));
              dy2 := unsigned(resize(dy_s*dy_s, 34));
              d2  := resize(dx2, 35) + resize(dy2, 35);

              if d2 < best_d2 then
                second_d2 <= best_d2;
                second_id <= best_id;
                best_d2   <= d2;
                best_id   <= to_unsigned(scan_i, 8);
              elsif d2 < second_d2 then
                second_d2 <= d2;
                second_id <= to_unsigned(scan_i, 8);
              end if;
            end if;

            if scan_i = MAX_NODES-1 then
              s1_id <= best_id;
              s2_id <= second_id;
              ph <= P_UPD_RD;
            else
              scan_i <= scan_i + 1;
              ph <= P_WIN_REQ;
            end if;

          -------------------------------------------------------------------
          -- Update error(s1) + move s1 (RMW)
          -------------------------------------------------------------------
          when P_UPD_RD =>
            node_raddr <= s1_id;
            ph <= P_UPD_WAIT;

          when P_UPD_WAIT =>
            ph <= P_UPD_WR;

          when P_UPD_WR =>
            w   := node_rdata;
            act := get_act(w);
            deg := get_deg(w);
            nx  := get_x(w);
            ny  := get_y(w);

            cur_err := get_err(w);

            -- If winner was never updated (all inactive), avoid INF explode
            if best_d2 = D2_INF then
              add_err := (others => '0');
            else
              add_err := resize(shift_right(best_d2, ERR_SHIFT), 32);
            end if;

            new_err := cur_err + add_err;
            dbg_err32 <= new_err;

            -- move s1 towards sample with eps=0.3
            dx_s := resize(sample_x, 17) - resize(nx, 17);
            dy_s := resize(sample_y, 17) - resize(ny, 17);

            -- IMPORTANT FIX: keep operand widths (17 * 9 -> 26)
            mulx := dx_s * EPS_Q8_S9; -- 26-bit result
            muly := dy_s * EPS_Q8_S9;

            delx := resize(shift_right(mulx, EPS_WIN_SH), 17);
            dely := resize(shift_right(muly, EPS_WIN_SH), 17);

            nx_new := resize(nx, 18) + resize(delx, 18);
            ny_new := resize(ny, 18) + resize(dely, 18);

            sx := sat_s16(nx_new);
            sy := sat_s16(ny_new);

            -- NEW: store debug s1 position (after update)
            dbg_s1_x <= sx;
            dbg_s1_y <= sy;

            node_we    <= '1';
            node_waddr <= s1_id;
            node_wdata <= pack_node(
                            sx,
                            sy,
                            act,
                            deg,
                            new_err
                          );

            ph <= P_DBG_EDGE_REQ;

          -------------------------------------------------------------------
          -- Debug: read edge(0,1)
          -------------------------------------------------------------------
          when P_DBG_EDGE_REQ =>
            idx01 := edge_idx(0, 1, MAX_NODES);
            edge_raddr <= to_unsigned(idx01, 13);
            ph <= P_DBG_EDGE_WAIT;

          when P_DBG_EDGE_WAIT =>
            ph <= P_TX_PREP;

          -------------------------------------------------------------------
          -- Prepare TLV debug frame
          -------------------------------------------------------------------
          when P_TX_PREP =>
            -- 26 bytes:
            -- A5 type, A6 s1, A7 s2, A8 edge01,
            -- AA..AD err32,
            -- AE/AF x_s1,
            -- B0/B2 y_s1,
            -- A9 sample (end marker)
            tx_buf(0)  <= B_A5;
            tx_buf(1)  <= x"10"; -- type/phase code: 0x10 = LOOP_DONE

            tx_buf(2)  <= B_A6;
            tx_buf(3)  <= std_logic_vector(resize(s1_id, 8));

            tx_buf(4)  <= B_A7;
            tx_buf(5)  <= std_logic_vector(resize(s2_id, 8));

            tx_buf(6)  <= B_A8;
            tx_buf(7)  <= edge_rdata;

            tx_buf(8)  <= B_AA;
            tx_buf(9)  <= std_logic_vector(dbg_err32(7 downto 0));

            tx_buf(10) <= B_AB;
            tx_buf(11) <= std_logic_vector(dbg_err32(15 downto 8));

            tx_buf(12) <= B_AC;
            tx_buf(13) <= std_logic_vector(dbg_err32(23 downto 16));

            tx_buf(14) <= B_AD;
            tx_buf(15) <= std_logic_vector(dbg_err32(31 downto 24));

            -- NEW: s1 x/y (signed 16)
            tx_buf(16) <= B_AE;
            tx_buf(17) <= std_logic_vector(dbg_s1_x(7 downto 0));
            tx_buf(18) <= B_AF;
            tx_buf(19) <= std_logic_vector(dbg_s1_x(15 downto 8));

            tx_buf(20) <= B_B0;
            tx_buf(21) <= std_logic_vector(dbg_s1_y(7 downto 0));
            tx_buf(22) <= B_B2;
            tx_buf(23) <= std_logic_vector(dbg_s1_y(15 downto 8));

            tx_buf(24) <= B_A9;
            tx_buf(25) <= std_logic_vector(to_unsigned(samp_i mod 256, 8));

            tx_len <= 26;
            tx_idx <= 0;
            ph <= P_TX_SEND;

          -------------------------------------------------------------------
          -- Send bytes over UART
          -------------------------------------------------------------------
          when P_TX_SEND =>
            if (tx_busy_i = '0') and (tx_inflight = '0') then
              tx_start_o  <= '1';
              tx_data_o   <= tx_buf(tx_idx);
              tx_inflight <= '1';
              ph <= P_TX_WAIT;
            end if;

          when P_TX_WAIT =>
            if (tx_done_i = '1') or (tx_inflight = '0') then
              if tx_idx = tx_len-1 then
                done_p <= '1';
                ph <= P_NEXT;
              else
                tx_idx <= tx_idx + 1;
                ph <= P_TX_SEND;
              end if;
            end if;

          -------------------------------------------------------------------
          -- Next sample and loop forever
          -------------------------------------------------------------------
          when P_NEXT =>
            if samp_i = DATA_WORDS-1 then
              samp_i <= 0;
            else
              samp_i <= samp_i + 1;
            end if;

            delay_cnt <= integer(DELAY_TICKS);
            ph <= P_WAIT_100MS;

          when others =>
            ph <= P_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture;
