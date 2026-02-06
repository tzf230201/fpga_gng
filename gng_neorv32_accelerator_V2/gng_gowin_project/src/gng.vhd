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

    -- error scaling: err += (d2 >> ERR_SHIFT)
    ERR_SHIFT : natural := 4
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;
    start_i : in  std_logic;

    -- dataset stream (word32: y16|x16 OR x16|y16 sesuai packing kamu.receiver
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
  -- Types / subtypes
  ---------------------------------------------------------------------------
  subtype s16 is signed(15 downto 0);
  subtype u8  is unsigned(7 downto 0);
  subtype u32 is unsigned(31 downto 0);

  ---------------------------------------------------------------------------
  -- BRAM packing for node
  -- Layout (80-bit):
  -- [15:0]   x (s16)
  -- [31:16]  y (s16)
  -- [32]     active (1)
  -- [40:33]  degree (u8)
  -- [72:41]  error (u32)
  -- [79:73]  padding (7)
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

  function get_x(w : std_logic_vector(NODE_W-1 downto 0)) return s16 is
  begin
    return signed(w(X_H downto X_L));
  end function;

  function get_y(w : std_logic_vector(NODE_W-1 downto 0)) return s16 is
  begin
    return signed(w(Y_H downto Y_L));
  end function;

  function get_act(w : std_logic_vector(NODE_W-1 downto 0)) return std_logic is
  begin
    return w(ACT_B);
  end function;

  function get_deg(w : std_logic_vector(NODE_W-1 downto 0)) return u8 is
  begin
    return unsigned(w(DEG_H downto DEG_L));
  end function;

  function get_err(w : std_logic_vector(NODE_W-1 downto 0)) return u32 is
  begin
    return unsigned(w(ERR_H downto ERR_L));
  end function;

  function set_err(w : std_logic_vector(NODE_W-1 downto 0); err : u32)
    return std_logic_vector is
    variable ww : std_logic_vector(NODE_W-1 downto 0) := w;
  begin
    ww(ERR_H downto ERR_L) := std_logic_vector(err);
    return ww;
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
  signal edge_raddr : unsigned(12 downto 0) := (others => '0'); -- up to 8191 ok
  signal edge_rdata : std_logic_vector(7 downto 0) := (others => '0');

  signal edge_we    : std_logic := '0';
  signal edge_waddr : unsigned(12 downto 0) := (others => '0');
  signal edge_wdata : std_logic_vector(7 downto 0) := (others => '0');

  ---------------------------------------------------------------------------
  -- Dataset sample latch (word32 = x16|y16)
  ---------------------------------------------------------------------------
  signal data_addr : unsigned(6 downto 0) := (others => '0');
  signal sample_w  : std_logic_vector(31 downto 0) := (others => '0');
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
    P_INIT_SEED_EDGE,

    -- run per sample
    P_WAIT_100MS,
    P_SAMPLE_REQ,
    P_SAMPLE_WAIT,

    -- winner scan
    P_WIN_SETUP,
    P_WIN_REQ,
    P_WIN_WAIT,
    P_WIN_EVAL,

    -- update error for s1 (RMW)
    P_ERR_RD,
    P_ERR_WAIT,
    P_ERR_WR,

    -- debug UART (also reads edge01 to keep edge BRAM "used")
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

  -- IMPORTANT: prevent rewriting node1 (err reset) each time samp_i wraps
  signal patched_node1 : std_logic := '0';

  -- debug latched error (new error after update)
  signal dbg_err32 : u32 := (others => '0');

  ---------------------------------------------------------------------------
  -- UART TX helper
  ---------------------------------------------------------------------------
  signal tx_inflight : std_logic := '0';
  signal tx_idx      : natural range 0 to 14 := 0; -- 15 bytes
  signal tx_len      : natural range 0 to 15 := 0;

  type tx_buf_t is array (0 to 14) of std_logic_vector(7 downto 0);
  signal tx_buf : tx_buf_t := (others => (others => '0'));

  -- constants for debug TLV tags
  constant B_A5 : std_logic_vector(7 downto 0) := x"A5";
  constant B_A6 : std_logic_vector(7 downto 0) := x"A6";
  constant B_A7 : std_logic_vector(7 downto 0) := x"A7";
  constant B_A8 : std_logic_vector(7 downto 0) := x"A8";
  constant B_A9 : std_logic_vector(7 downto 0) := x"A9";
  constant B_AA : std_logic_vector(7 downto 0) := x"AA";

begin

  ---------------------------------------------------------------------------
  -- Outputs
  ---------------------------------------------------------------------------
  data_raddr_o <= data_addr;
  gng_busy_o   <= started;
  gng_done_o   <= done_p;

  ---------------------------------------------------------------------------
  -- Node BRAM (1R1W) - read-first
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
  -- Edge BRAM (1R1W) - read-first
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
  -- Phase controller (single FSM)
  ---------------------------------------------------------------------------
  process(clk_i)
    variable dx_s : signed(16 downto 0);
    variable dy_s : signed(16 downto 0);
    variable dx2  : unsigned(33 downto 0);
    variable dy2  : unsigned(33 downto 0);
    variable d2   : unsigned(34 downto 0);

    variable w    : std_logic_vector(NODE_W-1 downto 0);
    variable act  : std_logic;
    variable nx   : s16;
    variable ny   : s16;

    variable cur_err : u32;
    variable add_err : u32;

    constant D2_INF : unsigned(34 downto 0) := (others => '1');

    variable idx01 : natural;
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        ph <= P_IDLE;
        started <= '0';

        node_we <= '0';
        edge_we <= '0';

        data_addr <= (others => '0');
        sample_w  <= (others => '0');
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

        done_p <= '0';

        patched_node1 <= '0';
        dbg_err32 <= (others => '0');

        -- UART default
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

        tx_start_o <= '0'; -- pulse

        -- clear tx inflight robustly
        if tx_inflight = '1' then
          if (tx_done_i = '1') or (tx_busy_i = '0') then
            tx_inflight <= '0';
          end if;
        end if;

        case ph is

          -------------------------------------------------------------------
          -- WAIT START
          -------------------------------------------------------------------
          when P_IDLE =>
            started <= '0';
            if start_i = '1' then
              started <= '1';
              init_n <= 0;
              init_e <= 0;
              samp_i <= 0;
              patched_node1 <= '0';
              dbg_err32 <= (others => '0');
              ph <= P_INIT_CLR_NODE;
            end if;

          -------------------------------------------------------------------
          -- INIT: clear node mem (1 entry per cycle)
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
          -- INIT seed node0
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
          -- INIT seed node1
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
            ph <= P_INIT_SEED_EDGE;

          -------------------------------------------------------------------
          -- INIT edge(0,1) + set degree(0)=1
          -- node1 degree akan dipatch SEKALI di P_WAIT_100MS (patched_node1 flag)
          -------------------------------------------------------------------
          when P_INIT_SEED_EDGE =>
            idx01 := edge_idx(0, 1, MAX_NODES);

            edge_we    <= '1';
            edge_waddr <= to_unsigned(idx01, 13);
            edge_wdata <= std_logic_vector(to_unsigned(1, 8));

            -- set node0 degree=1
            node_we    <= '1';
            node_waddr <= to_unsigned(0, 8);
            node_wdata <= pack_node(
                            to_signed(INIT_X0, 16),
                            to_signed(INIT_Y0, 16),
                            '1',
                            to_unsigned(1,8),
                            (others => '0')
                          );

            delay_cnt <= integer(DELAY_TICKS);
            ph <= P_WAIT_100MS;

          -------------------------------------------------------------------
          -- Delay 100ms between loops; also patch node1 degree exactly once
          -------------------------------------------------------------------
          when P_WAIT_100MS =>
            -- patch node1 degree only once per run (avoid periodic err reset)
            if patched_node1 = '0' then
              node_we    <= '1';
              node_waddr <= to_unsigned(1, 8);
              node_wdata <= pack_node(
                              to_signed(INIT_X1, 16),
                              to_signed(INIT_Y1, 16),
                              '1',
                              to_unsigned(1,8),
                              (others => '0')
                            );
              patched_node1 <= '1';
            end if;

            if delay_cnt <= 0 then
              ph <= P_SAMPLE_REQ;
            else
              delay_cnt <= delay_cnt - 1;
            end if;

          -------------------------------------------------------------------
          -- Sample read request (1-cycle latency)
          -------------------------------------------------------------------
          when P_SAMPLE_REQ =>
            data_addr <= to_unsigned(samp_i, 7);
            ph <= P_SAMPLE_WAIT;

          when P_SAMPLE_WAIT =>
            sample_w <= data_rdata_i;
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
            node_raddr <= (others => '0');
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
          -- Evaluate current node
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
              ph <= P_ERR_RD;
            else
              scan_i <= scan_i + 1;
              ph <= P_WIN_REQ;
            end if;

          -------------------------------------------------------------------
          -- Update error for s1 (RMW)
          -------------------------------------------------------------------
          when P_ERR_RD =>
            node_raddr <= s1_id;
            ph <= P_ERR_WAIT;

          when P_ERR_WAIT =>
            ph <= P_ERR_WR;

          when P_ERR_WR =>
            w := node_rdata;
            cur_err := get_err(w);

            -- add_err = best_d2 >> ERR_SHIFT (resize to 32)
            add_err := resize(shift_right(best_d2, ERR_SHIFT), 32);

            -- latch updated error for debug TX
            dbg_err32 <= cur_err + add_err;

            node_we    <= '1';
            node_waddr <= s1_id;
            node_wdata <= set_err(w, cur_err + add_err);

            ph <= P_DBG_EDGE_REQ;

          -------------------------------------------------------------------
          -- Debug: read edge(0,1) age so edge BRAM is also "used"
          -------------------------------------------------------------------
          when P_DBG_EDGE_REQ =>
            idx01 := edge_idx(0, 1, MAX_NODES);
            edge_raddr <= to_unsigned(idx01, 13);
            ph <= P_DBG_EDGE_WAIT;

          when P_DBG_EDGE_WAIT =>
            ph <= P_TX_PREP;

          -------------------------------------------------------------------
          -- Prepare TX buffer (TLV):
          -- A5 <type>, A6 <s1>, A7 <s2>, A8 <edge01>,
          -- AA <err32 LSB..MSB>, A9 <sample>
          -------------------------------------------------------------------
          when P_TX_PREP =>
            tx_buf(0) <= B_A5;
            tx_buf(1) <= std_logic_vector(to_unsigned(16#10#, 8)); -- type "WINNER_DONE"

            tx_buf(2) <= B_A6;
            tx_buf(3) <= std_logic_vector(resize(s1_id, 8));

            tx_buf(4) <= B_A7;
            tx_buf(5) <= std_logic_vector(resize(s2_id, 8));

            tx_buf(6) <= B_A8;
            tx_buf(7) <= edge_rdata;

            tx_buf(8)  <= B_AA;
            tx_buf(9)  <= std_logic_vector(dbg_err32(7 downto 0));
            tx_buf(10) <= std_logic_vector(dbg_err32(15 downto 8));
            tx_buf(11) <= std_logic_vector(dbg_err32(23 downto 16));
            tx_buf(12) <= std_logic_vector(dbg_err32(31 downto 24));

            tx_buf(13) <= B_A9;
            tx_buf(14) <= std_logic_vector(to_unsigned(samp_i mod 256, 8));

            tx_len <= 15;
            tx_idx <= 0;
            ph <= P_TX_SEND;

          -------------------------------------------------------------------
          -- Send bytes over UART (global uart_tx)
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
