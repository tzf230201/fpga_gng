-- gng.vhd (FULL) : winner + move + age neighbor + connect/reset + prune/iso + insert every LAMBDA
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

    ERR_SHIFT : natural := 4;

    -- prune threshold (age in "real age", not stored form)
    A_MAX    : natural := 50;

    -- insert interval
    LAMBDA   : natural := 100
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;
    start_i : in  std_logic;

    data_raddr_o : out unsigned(6 downto 0);
    data_rdata_i : in  std_logic_vector(31 downto 0);

    gng_busy_o : out std_logic;
    gng_done_o : out std_logic;

    tx_busy_i  : in  std_logic;
    tx_done_i  : in  std_logic;
    tx_start_o : out std_logic;
    tx_data_o  : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of gng is

  subtype s16 is signed(15 downto 0);
  subtype u8  is unsigned(7 downto 0);
  subtype u32 is unsigned(31 downto 0);

  -- eps winner = 0.3 (Q8) => 77
  constant EPS_WIN_Q8 : integer := 77;
  constant EPS_WIN_SH : natural := 8;

  -- eps neighbor = 0.001 (Q16) => 66
  constant EPS_N_Q16  : integer := 66;
  constant EPS_N_SH   : natural := 16;

  -- Node packing (80-bit)
  constant NODE_W : natural := 80;

  -- *** FIX for Gowin: define subtype for constrained std_logic_vector ***
  subtype node_word_t is std_logic_vector(NODE_W-1 downto 0);

  constant X_L   : natural := 0;
  constant X_H   : natural := 15;
  constant Y_L   : natural := 16;
  constant Y_H   : natural := 31;
  constant ACT_B : natural := 32;
  constant DEG_L : natural := 33;
  constant DEG_H : natural := 40;
  constant ERR_L : natural := 41;
  constant ERR_H : natural := 72;

  -- stored edge value: 0=no edge, 1..255 means connected, stored = age+1
  function age_limit_stored(a : natural) return unsigned is
    variable v : natural;
  begin
    if a >= 254 then
      v := 255;
    else
      v := a + 1;
    end if;
    return to_unsigned(v, 8);
  end function;

  constant A_MAX_STORED : unsigned(7 downto 0) := age_limit_stored(A_MAX);

  function pack_node(x : s16; y : s16; act : std_logic; deg : u8; err : u32)
    return node_word_t is
    variable w : node_word_t := (others => '0');
  begin
    w(X_H downto X_L) := std_logic_vector(x);
    w(Y_H downto Y_L) := std_logic_vector(y);
    w(ACT_B) := act;
    w(DEG_H downto DEG_L) := std_logic_vector(deg);
    w(ERR_H downto ERR_L) := std_logic_vector(err);
    return w;
  end function;

  function get_x(w : node_word_t) return s16 is
  begin return signed(w(X_H downto X_L)); end;
  function get_y(w : node_word_t) return s16 is
  begin return signed(w(Y_H downto Y_L)); end;
  function get_act(w : node_word_t) return std_logic is
  begin return w(ACT_B); end;
  function get_deg(w : node_word_t) return u8 is
  begin return unsigned(w(DEG_H downto DEG_L)); end;
  function get_err(w : node_word_t) return u32 is
  begin return unsigned(w(ERR_H downto ERR_L)); end;

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

  -- Edge memory (upper triangle)
  constant EDGE_N : natural := (MAX_NODES * (MAX_NODES - 1)) / 2;

  function edge_base(i : natural; N : natural) return natural is
  begin
    return (i * (2*N - i - 1)) / 2;
  end function;

  function edge_idx(i : natural; j : natural; N : natural) return natural is
  begin
    -- assume i<j
    return edge_base(i, N) + (j - i - 1);
  end function;

  attribute syn_ramstyle : string;

  type node_mem_t is array (0 to MAX_NODES-1) of node_word_t;
  signal node_mem : node_mem_t;
  attribute syn_ramstyle of node_mem : signal is "block_ram";

  type edge_mem_t is array (0 to EDGE_N-1) of std_logic_vector(7 downto 0);
  signal edge_mem : edge_mem_t;
  attribute syn_ramstyle of edge_mem : signal is "block_ram";

  -- Node BRAM ports
  signal node_raddr : unsigned(7 downto 0) := (others => '0');
  signal node_rdata : node_word_t := (others => '0');
  signal node_we    : std_logic := '0';
  signal node_waddr : unsigned(7 downto 0) := (others => '0');
  signal node_wdata : node_word_t := (others => '0');

  -- Edge BRAM ports
  signal edge_raddr : unsigned(12 downto 0) := (others => '0');
  signal edge_rdata : std_logic_vector(7 downto 0) := (others => '0');
  signal edge_we    : std_logic := '0';
  signal edge_waddr : unsigned(12 downto 0) := (others => '0');
  signal edge_wdata : std_logic_vector(7 downto 0) := (others => '0');

  -- dataset
  signal data_addr : unsigned(6 downto 0) := (others => '0');
  signal sample_x  : s16 := (others => '0');
  signal sample_y  : s16 := (others => '0');

  type phase_t is (
    P_IDLE,

    P_INIT_CLR_NODE,
    P_INIT_CLR_EDGE,
    P_INIT_SEED0,
    P_INIT_SEED1,
    P_INIT_SEED_EDGE0,
    P_INIT_SEED_EDGE1,

    P_WAIT_100MS,
    P_SAMPLE_REQ,
    P_SAMPLE_WAIT,

    P_WIN_SETUP,
    P_WIN_REQ,
    P_WIN_WAIT,
    P_WIN_EVAL,

    P_UPD_RD,
    P_UPD_WAIT,
    P_UPD_WR,

    P_NB_SETUP,
    P_NB_NODE_REQ,
    P_NB_NODE_WAIT,
    P_NB_NODE_EVAL,
    P_NB_EDGE_WAIT,
    P_NB_EDGE_EVAL,

    P_S1_DEG_WR,

    P_CONN_SETUP,
    P_CONN_EDGE_WAIT,
    P_CONN_EDGE_WR,
    P_CONN_DEGA_RD,
    P_CONN_DEGA_WAIT,
    P_CONN_DEGA_WR,
    P_CONN_DEGB_RD,
    P_CONN_DEGB_WAIT,
    P_CONN_DEGB_WR,

    -- insert every LAMBDA
    P_INS_CHECK,
    P_INS_FIND_SETUP,
    P_INS_FIND_REQ,
    P_INS_FIND_WAIT,
    P_INS_FIND_EVAL,
    P_INS_CLR_EDGE,

    P_INS_EDGE_S1S2_RD,
    P_INS_EDGE_S1S2_WAIT,
    P_INS_EDGE_S1S2_EVAL,
    P_INS_EDGE_S1S2_CLR_WR,

    P_INS_S2_RD,
    P_INS_S2_WAIT,
    P_INS_NODE_WR,
    P_INS_EDGE1_WR,
    P_INS_EDGE2_WR,
    P_INS_DEG_S1_RD,
    P_INS_DEG_S1_WAIT,
    P_INS_DEG_S1_WR,
    P_INS_DEG_S2_RD,
    P_INS_DEG_S2_WAIT,
    P_INS_DEG_S2_WR,

    -- debug reads (RD->WAIT->EVAL)
    P_DBG_EDGE01_REQ,
    P_DBG_EDGE01_WAIT,
    P_DBG_EDGE01_EVAL,

    P_DBG_DEG_S1_RD,
    P_DBG_DEG_S1_WAIT,
    P_DBG_DEG_S1_EVAL,

    P_DBG_DEG_S2_RD,
    P_DBG_DEG_S2_WAIT,
    P_DBG_DEG_S2_EVAL,

    P_TX_PREP,
    P_TX_SEND,
    P_TX_WAIT,
    P_NEXT
  );
  signal ph : phase_t := P_IDLE;

  signal started : std_logic := '0';

  signal init_n : natural range 0 to MAX_NODES-1 := 0;
  signal init_e : natural range 0 to EDGE_N-1 := 0;

  signal samp_i : natural range 0 to DATA_WORDS-1 := 0;

  constant DELAY_TICKS : natural := (CLOCK_HZ/1000) * DBG_DELAY_MS;
  signal delay_cnt : integer range 0 to integer(DELAY_TICKS) := 0;

  -- winner scan
  signal scan_i : natural range 0 to MAX_NODES := 0;
  signal best_id    : u8 := (others => '0');
  signal second_id  : u8 := (others => '0');
  signal best_d2    : unsigned(34 downto 0) := (others => '1');
  signal second_d2  : unsigned(34 downto 0) := (others => '1');

  signal s1_id : u8 := (others => '0');
  signal s2_id : u8 := (others => '0');
  signal s2_valid : std_logic := '0';

  signal done_p : std_logic := '0';

  -- s1 regs for later writeback
  signal s1_act_reg : std_logic := '0';
  signal s1_deg_reg : u8 := (others => '0');
  signal s1_err_reg : u32 := (others => '0');

  -- debug core
  signal dbg_err32 : u32 := (others => '0');
  signal dbg_s1x   : s16 := (others => '0');
  signal dbg_s1y   : s16 := (others => '0');

  -- prune/iso flags
  signal rm_flag    : std_logic := '0';
  signal iso_flag   : std_logic := '0';
  signal iso_id_dbg : u8 := (others => '0');

  -- node count
  signal node_count : u8 := (others => '0');

  -- connect debug
  signal dbg_es1s2_pre : std_logic_vector(7 downto 0) := (others => '0');

  -- insertion control
  signal lambda_cnt : natural range 0 to LAMBDA-1 := 0;
  signal insert_now : std_logic := '0';

  signal ins_i    : natural range 0 to MAX_NODES-1 := 0;
  signal ins_free : natural range 0 to MAX_NODES-1 := 0;
  signal ins_j    : natural range 0 to MAX_NODES-1 := 0;

  signal ins_s2x  : s16 := (others => '0');
  signal ins_s2y  : s16 := (others => '0');

  signal ins_flag : std_logic := '0';
  signal ins_id_dbg : u8 := (others => '0');

  signal ins_es1s2_pre  : std_logic_vector(7 downto 0) := (others => '0');
  signal ins_es1s2_addr : unsigned(12 downto 0) := (others => '0');

  -- dbg edge01
  signal dbg_e01 : std_logic_vector(7 downto 0) := (others => '0');

  -- dbg degrees
  signal dbg_deg_s1 : u8 := (others => '0');
  signal dbg_deg_s2 : u8 := (others => '0');

  -- UART TX
  signal tx_inflight : std_logic := '0';
  signal tx_idx      : natural range 0 to 63 := 0;
  signal tx_len      : natural range 0 to 64 := 0;

  type tx_buf_t is array (0 to 63) of std_logic_vector(7 downto 0);
  signal tx_buf : tx_buf_t := (others => (others => '0'));

  -- Tags
  constant B_A5 : std_logic_vector(7 downto 0) := x"A5";
  constant B_A6 : std_logic_vector(7 downto 0) := x"A6";
  constant B_A7 : std_logic_vector(7 downto 0) := x"A7";
  constant B_A8 : std_logic_vector(7 downto 0) := x"A8";
  constant B_A9 : std_logic_vector(7 downto 0) := x"A9";

  constant B_AA : std_logic_vector(7 downto 0) := x"AA";
  constant B_AB : std_logic_vector(7 downto 0) := x"AB";
  constant B_AC : std_logic_vector(7 downto 0) := x"AC";
  constant B_AD : std_logic_vector(7 downto 0) := x"AD";

  constant B_AE : std_logic_vector(7 downto 0) := x"AE";
  constant B_AF : std_logic_vector(7 downto 0) := x"AF";
  constant B_B0 : std_logic_vector(7 downto 0) := x"B0";
  constant B_B1 : std_logic_vector(7 downto 0) := x"B1";

  constant B_C0 : std_logic_vector(7 downto 0) := x"C0";
  constant B_C1 : std_logic_vector(7 downto 0) := x"C1";
  constant B_C2 : std_logic_vector(7 downto 0) := x"C2";
  constant B_C3 : std_logic_vector(7 downto 0) := x"C3";
  constant B_C4 : std_logic_vector(7 downto 0) := x"C4";
  constant B_C5 : std_logic_vector(7 downto 0) := x"C5";
  constant B_C6 : std_logic_vector(7 downto 0) := x"C6";
  constant B_C7 : std_logic_vector(7 downto 0) := x"C7";
  constant B_C8 : std_logic_vector(7 downto 0) := x"C8";
  constant B_C9 : std_logic_vector(7 downto 0) := x"C9";

begin

  data_raddr_o <= data_addr;
  gng_busy_o   <= started;
  gng_done_o   <= done_p;

  -- Node BRAM
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      node_rdata <= node_mem(to_integer(node_raddr));
      if node_we = '1' then
        node_mem(to_integer(node_waddr)) <= node_wdata;
      end if;
    end if;
  end process;

  -- Edge BRAM
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      edge_rdata <= edge_mem(to_integer(edge_raddr));
      if edge_we = '1' then
        edge_mem(to_integer(edge_waddr)) <= edge_wdata;
      end if;
    end if;
  end process;

  process(clk_i)
    variable dx_s : signed(16 downto 0);
    variable dy_s : signed(16 downto 0);

    variable dx2_s : signed(33 downto 0);
    variable dy2_s : signed(33 downto 0);
    variable dx2   : unsigned(33 downto 0);
    variable dy2   : unsigned(33 downto 0);
    variable d2    : unsigned(34 downto 0);

    variable w    : node_word_t;
    variable act  : std_logic;
    variable deg  : u8;
    variable nx   : s16;
    variable ny   : s16;

    variable cur_err : u32;
    variable add_err : u32;
    variable new_err : u32;

    variable mulx_w : signed(32 downto 0);
    variable muly_w : signed(32 downto 0);
    variable delx_w : signed(16 downto 0);
    variable dely_w : signed(16 downto 0);
    variable nx_new : signed(17 downto 0);
    variable ny_new : signed(17 downto 0);

    variable dx_n   : signed(16 downto 0);
    variable dy_n   : signed(16 downto 0);
    variable mulx_n : signed(34 downto 0);
    variable muly_n : signed(34 downto 0);
    variable delx_n : signed(16 downto 0);
    variable dely_n : signed(16 downto 0);
    variable nx_nb_new : signed(17 downto 0);
    variable ny_nb_new : signed(17 downto 0);

    variable age_u  : unsigned(7 downto 0);
    variable age_new_u : unsigned(7 downto 0);

    variable i1, i2 : integer;
    variable idxe   : natural;

    variable sumx : signed(16 downto 0);
    variable sumy : signed(16 downto 0);
    variable rx   : signed(16 downto 0);
    variable ry   : signed(16 downto 0);

    variable s1_act_final : std_logic;

    constant D2_INF : unsigned(34 downto 0) := (others => '1');
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
        s2_valid <= '0';

        done_p <= '0';

        dbg_err32 <= (others => '0');
        dbg_s1x <= (others => '0');
        dbg_s1y <= (others => '0');

        s1_act_reg <= '0';
        s1_deg_reg <= (others => '0');
        s1_err_reg <= (others => '0');

        rm_flag <= '0';
        iso_flag <= '0';
        iso_id_dbg <= (others => '0');

        node_count <= (others => '0');
        dbg_es1s2_pre <= (others => '0');

        lambda_cnt <= 0;
        insert_now <= '0';

        ins_i <= 0;
        ins_free <= 0;
        ins_j <= 0;
        ins_s2x <= (others => '0');
        ins_s2y <= (others => '0');

        ins_flag <= '0';
        ins_id_dbg <= (others => '0');

        ins_es1s2_pre <= (others => '0');
        ins_es1s2_addr <= (others => '0');

        dbg_e01 <= (others => '0');
        dbg_deg_s1 <= (others => '0');
        dbg_deg_s2 <= (others => '0');

        tx_start_o <= '0';
        tx_data_o <= (others => '0');
        tx_inflight <= '0';
        tx_idx <= 0;
        tx_len <= 0;

      else
        -- defaults
        node_we <= '0';
        edge_we <= '0';
        done_p  <= '0';
        tx_start_o <= '0';

        if tx_inflight = '1' then
          if (tx_done_i = '1') or (tx_busy_i = '0') then
            tx_inflight <= '0';
          end if;
        end if;

        case ph is
          when P_IDLE =>
            started <= '0';
            if start_i = '1' then
              started <= '1';
              init_n <= 0;
              ph <= P_INIT_CLR_NODE;
            end if;

          when P_INIT_CLR_NODE =>
            node_we <= '1';
            node_waddr <= to_unsigned(init_n, 8);
            node_wdata <= (others => '0');
            if init_n = MAX_NODES-1 then
              init_e <= 0;
              ph <= P_INIT_CLR_EDGE;
            else
              init_n <= init_n + 1;
            end if;

          when P_INIT_CLR_EDGE =>
            edge_we <= '1';
            edge_waddr <= to_unsigned(init_e, 13);
            edge_wdata <= (others => '0');
            if init_e = EDGE_N-1 then
              ph <= P_INIT_SEED0;
            else
              init_e <= init_e + 1;
            end if;

          when P_INIT_SEED0 =>
            node_we <= '1';
            node_waddr <= to_unsigned(0,8);
            node_wdata <= pack_node(to_signed(INIT_X0,16), to_signed(INIT_Y0,16), '1', to_unsigned(0,8), (others=>'0'));
            ph <= P_INIT_SEED1;

          when P_INIT_SEED1 =>
            node_we <= '1';
            node_waddr <= to_unsigned(1,8);
            node_wdata <= pack_node(to_signed(INIT_X1,16), to_signed(INIT_Y1,16), '1', to_unsigned(0,8), (others=>'0'));
            ph <= P_INIT_SEED_EDGE0;

          when P_INIT_SEED_EDGE0 =>
            idxe := edge_idx(0,1,MAX_NODES);
            edge_we <= '1';
            edge_waddr <= to_unsigned(idxe, 13);
            edge_wdata <= x"01";

            node_we <= '1';
            node_waddr <= to_unsigned(0,8);
            node_wdata <= pack_node(to_signed(INIT_X0,16), to_signed(INIT_Y0,16), '1', to_unsigned(1,8), (others=>'0'));
            ph <= P_INIT_SEED_EDGE1;

          when P_INIT_SEED_EDGE1 =>
            node_we <= '1';
            node_waddr <= to_unsigned(1,8);
            node_wdata <= pack_node(to_signed(INIT_X1,16), to_signed(INIT_Y1,16), '1', to_unsigned(1,8), (others=>'0'));

            node_count <= to_unsigned(2,8);
            samp_i <= 0;
            delay_cnt <= integer(DELAY_TICKS);
            ph <= P_WAIT_100MS;

          when P_WAIT_100MS =>
            if delay_cnt <= 0 then
              ph <= P_SAMPLE_REQ;
            else
              delay_cnt <= delay_cnt - 1;
            end if;

          when P_SAMPLE_REQ =>
            if lambda_cnt = LAMBDA-1 then
              lambda_cnt <= 0;
              insert_now <= '1';
            else
              lambda_cnt <= lambda_cnt + 1;
              insert_now <= '0';
            end if;

            data_addr <= to_unsigned(samp_i, 7);
            ph <= P_SAMPLE_WAIT;

          when P_SAMPLE_WAIT =>
            sample_x <= signed(data_rdata_i(15 downto 0));
            sample_y <= signed(data_rdata_i(31 downto 16));
            ph <= P_WIN_SETUP;

          when P_WIN_SETUP =>
            rm_flag  <= '0';
            iso_flag <= '0';
            ins_flag <= '0';

            best_d2   <= D2_INF;
            second_d2 <= D2_INF;
            best_id   <= (others=>'0');
            second_id <= (others=>'0');
            scan_i <= 0;
            ph <= P_WIN_REQ;

          when P_WIN_REQ =>
            node_raddr <= to_unsigned(scan_i,8);
            ph <= P_WIN_WAIT;

          when P_WIN_WAIT =>
            ph <= P_WIN_EVAL;

          when P_WIN_EVAL =>
            w := node_rdata;
            act := get_act(w);
            if act = '1' then
              nx := get_x(w);
              ny := get_y(w);

              dx_s := resize(sample_x,17) - resize(nx,17);
              dy_s := resize(sample_y,17) - resize(ny,17);

              dx2_s := dx_s * dx_s;
              dy2_s := dy_s * dy_s;

              dx2 := unsigned(dx2_s);
              dy2 := unsigned(dy2_s);

              d2 := resize(dx2,35) + resize(dy2,35);

              if d2 < best_d2 then
                second_d2 <= best_d2;
                second_id <= best_id;
                best_d2   <= d2;
                best_id   <= to_unsigned(scan_i,8);
              elsif d2 < second_d2 then
                second_d2 <= d2;
                second_id <= to_unsigned(scan_i,8);
              end if;
            end if;

            if scan_i = MAX_NODES-1 then
              s1_id <= best_id;
              s2_id <= second_id;
              if second_d2 = D2_INF then
                s2_valid <= '0';
              else
                s2_valid <= '1';
              end if;
              ph <= P_UPD_RD;
            else
              scan_i <= scan_i + 1;
              ph <= P_WIN_REQ;
            end if;

          when P_UPD_RD =>
            node_raddr <= s1_id;
            ph <= P_UPD_WAIT;

          when P_UPD_WAIT =>
            ph <= P_UPD_WR;

          when P_UPD_WR =>
            w := node_rdata;
            act := get_act(w);
            deg := get_deg(w);
            nx  := get_x(w);
            ny  := get_y(w);
            cur_err := get_err(w);

            if best_d2 = D2_INF then
              add_err := (others=>'0');
            else
              add_err := resize(shift_right(best_d2, ERR_SHIFT), 32);
            end if;

            new_err := cur_err + add_err;
            dbg_err32 <= new_err;

            dx_s := resize(sample_x,17) - resize(nx,17);
            dy_s := resize(sample_y,17) - resize(ny,17);

            mulx_w := dx_s * to_signed(EPS_WIN_Q8,16);
            muly_w := dy_s * to_signed(EPS_WIN_Q8,16);

            delx_w := resize(shift_right(mulx_w, EPS_WIN_SH), 17);
            dely_w := resize(shift_right(muly_w, EPS_WIN_SH), 17);

            nx_new := resize(nx,18) + resize(delx_w,18);
            ny_new := resize(ny,18) + resize(dely_w,18);

            dbg_s1x <= sat_s16(nx_new);
            dbg_s1y <= sat_s16(ny_new);

            s1_act_reg <= act;
            s1_deg_reg <= deg;
            s1_err_reg <= new_err;

            node_we <= '1';
            node_waddr <= s1_id;
            node_wdata <= pack_node(sat_s16(nx_new), sat_s16(ny_new), act, deg, new_err);

            ins_i <= 0;
            ph <= P_NB_SETUP;

          when P_NB_SETUP =>
            ins_i <= 0;
            ph <= P_NB_NODE_REQ;

          when P_NB_NODE_REQ =>
            node_raddr <= to_unsigned(ins_i, 8);
            ph <= P_NB_NODE_WAIT;

          when P_NB_NODE_WAIT =>
            ph <= P_NB_NODE_EVAL;

          when P_NB_NODE_EVAL =>
            w := node_rdata;
            act := get_act(w);
            deg := get_deg(w);
            nx  := get_x(w);
            ny  := get_y(w);
            cur_err := get_err(w);

            if (ins_i = to_integer(s1_id)) or (act = '0') then
              if ins_i = MAX_NODES-1 then
                ph <= P_S1_DEG_WR;
              else
                ins_i <= ins_i + 1;
                ph <= P_NB_NODE_REQ;
              end if;
            else
              i1 := to_integer(s1_id);
              i2 := ins_i;
              if i1 < i2 then
                idxe := edge_idx(i1, i2, MAX_NODES);
              else
                idxe := edge_idx(i2, i1, MAX_NODES);
              end if;
              edge_raddr <= to_unsigned(idxe, 13);
              ph <= P_NB_EDGE_WAIT;
            end if;

          when P_NB_EDGE_WAIT =>
            ph <= P_NB_EDGE_EVAL;

          when P_NB_EDGE_EVAL =>
            w := node_rdata;
            act := get_act(w);
            deg := get_deg(w);
            nx  := get_x(w);
            ny  := get_y(w);
            cur_err := get_err(w);

            age_u := unsigned(edge_rdata);

            if age_u /= 0 then
              if age_u = to_unsigned(255,8) then
                age_new_u := age_u;
              else
                age_new_u := age_u + 1;
              end if;

              if age_new_u > A_MAX_STORED then
                edge_we <= '1';
                edge_waddr <= edge_raddr;
                edge_wdata <= x"00";
                rm_flag <= '1';

                if s1_deg_reg > to_unsigned(0,8) then
                  s1_deg_reg <= s1_deg_reg - 1;
                end if;

                if deg > to_unsigned(0,8) then
                  deg := deg - 1;
                end if;

                if deg = to_unsigned(0,8) then
                  act := '0';
                  iso_flag <= '1';
                  iso_id_dbg <= to_unsigned(ins_i, 8);
                  if node_count > to_unsigned(0,8) then
                    node_count <= node_count - 1;
                  end if;
                end if;

                node_we <= '1';
                node_waddr <= to_unsigned(ins_i, 8);
                node_wdata <= pack_node(nx, ny, act, deg, cur_err);

              else
                edge_we <= '1';
                edge_waddr <= edge_raddr;
                edge_wdata <= std_logic_vector(age_new_u);

                dx_n := resize(dbg_s1x,17) - resize(nx,17);
                dy_n := resize(dbg_s1y,17) - resize(ny,17);

                mulx_n := dx_n * to_signed(EPS_N_Q16,18);
                muly_n := dy_n * to_signed(EPS_N_Q16,18);

                delx_n := resize(shift_right(mulx_n, EPS_N_SH), 17);
                dely_n := resize(shift_right(muly_n, EPS_N_SH), 17);

                nx_nb_new := resize(nx,18) + resize(delx_n,18);
                ny_nb_new := resize(ny,18) + resize(dely_n,18);

                node_we <= '1';
                node_waddr <= to_unsigned(ins_i, 8);
                node_wdata <= pack_node(sat_s16(nx_nb_new), sat_s16(ny_nb_new), act, deg, cur_err);
              end if;
            end if;

            if ins_i = MAX_NODES-1 then
              ph <= P_S1_DEG_WR;
            else
              ins_i <= ins_i + 1;
              ph <= P_NB_NODE_REQ;
            end if;

          when P_S1_DEG_WR =>
            s1_act_final := s1_act_reg;
            if (s1_act_reg = '1') and (s1_deg_reg = to_unsigned(0,8)) then
              s1_act_final := '0';
              iso_flag <= '1';
              iso_id_dbg <= s1_id; -- FIX
              if node_count > to_unsigned(0,8) then
                node_count <= node_count - 1;
              end if;
            end if;

            node_we <= '1';
            node_waddr <= s1_id;
            node_wdata <= pack_node(dbg_s1x, dbg_s1y, s1_act_final, s1_deg_reg, s1_err_reg);
            ph <= P_CONN_SETUP;

          when P_CONN_SETUP =>
            if (s2_valid = '0') or (s1_id = s2_id) then
              ph <= P_INS_CHECK;
            else
              i1 := to_integer(s1_id);
              i2 := to_integer(s2_id);
              if i1 < i2 then
                idxe := edge_idx(i1, i2, MAX_NODES);
              else
                idxe := edge_idx(i2, i1, MAX_NODES);
              end if;
              edge_raddr <= to_unsigned(idxe, 13);
              ph <= P_CONN_EDGE_WAIT;
            end if;

          when P_CONN_EDGE_WAIT =>
            ph <= P_CONN_EDGE_WR;

          when P_CONN_EDGE_WR =>
            dbg_es1s2_pre <= edge_rdata;
            edge_we <= '1';
            edge_waddr <= edge_raddr;
            edge_wdata <= x"01";

            if edge_rdata = x"00" then
              ph <= P_CONN_DEGA_RD;
            else
              ph <= P_INS_CHECK;
            end if;

          when P_CONN_DEGA_RD =>
            node_raddr <= s1_id;
            ph <= P_CONN_DEGA_WAIT;

          when P_CONN_DEGA_WAIT =>
            ph <= P_CONN_DEGA_WR;

          when P_CONN_DEGA_WR =>
            w := node_rdata;
            act := get_act(w);
            deg := get_deg(w);
            if act='1' then
              if deg < to_unsigned(255,8) then deg := deg + 1; end if;
              node_we <= '1';
              node_waddr <= s1_id;
              node_wdata <= pack_node(get_x(w), get_y(w), act, deg, get_err(w));
            end if;
            ph <= P_CONN_DEGB_RD;

          when P_CONN_DEGB_RD =>
            node_raddr <= s2_id;
            ph <= P_CONN_DEGB_WAIT;

          when P_CONN_DEGB_WAIT =>
            ph <= P_CONN_DEGB_WR;

          when P_CONN_DEGB_WR =>
            w := node_rdata;
            act := get_act(w);
            deg := get_deg(w);
            if act='1' then
              if deg < to_unsigned(255,8) then deg := deg + 1; end if;
              node_we <= '1';
              node_waddr <= s2_id;
              node_wdata <= pack_node(get_x(w), get_y(w), act, deg, get_err(w));
            end if;
            ph <= P_INS_CHECK;

          when P_INS_CHECK =>
            if (insert_now = '1') and (s2_valid='1') and (node_count < to_unsigned(MAX_NODES,8)) then
              ins_i <= 0;
              ph <= P_INS_FIND_SETUP;
            else
              ph <= P_DBG_EDGE01_REQ;
            end if;

          when P_INS_FIND_SETUP =>
            ins_i <= 0;
            ph <= P_INS_FIND_REQ;

          when P_INS_FIND_REQ =>
            node_raddr <= to_unsigned(ins_i,8);
            ph <= P_INS_FIND_WAIT;

          when P_INS_FIND_WAIT =>
            ph <= P_INS_FIND_EVAL;

          when P_INS_FIND_EVAL =>
            w := node_rdata;
            act := get_act(w);
            if act = '0' then
              ins_free <= ins_i;
              ins_j <= 0;
              ph <= P_INS_CLR_EDGE;
            else
              if ins_i = MAX_NODES-1 then
                ph <= P_DBG_EDGE01_REQ;
              else
                ins_i <= ins_i + 1;
                ph <= P_INS_FIND_REQ;
              end if;
            end if;

          when P_INS_CLR_EDGE =>
            if ins_j = MAX_NODES-1 then
              ph <= P_INS_EDGE_S1S2_RD;
            else
              if ins_j = ins_free then
                ins_j <= ins_j + 1;
              else
                i1 := ins_free;
                i2 := ins_j;
                if i1 < i2 then idxe := edge_idx(i1, i2, MAX_NODES);
                else idxe := edge_idx(i2, i1, MAX_NODES);
                end if;
                edge_we <= '1';
                edge_waddr <= to_unsigned(idxe, 13);
                edge_wdata <= x"00";
                ins_j <= ins_j + 1;
              end if;
            end if;

          when P_INS_EDGE_S1S2_RD =>
            i1 := to_integer(s1_id);
            i2 := to_integer(s2_id);
            if i1 < i2 then idxe := edge_idx(i1, i2, MAX_NODES);
            else idxe := edge_idx(i2, i1, MAX_NODES);
            end if;
            edge_raddr <= to_unsigned(idxe, 13);
            ph <= P_INS_EDGE_S1S2_WAIT;

          when P_INS_EDGE_S1S2_WAIT =>
            ph <= P_INS_EDGE_S1S2_EVAL;

          when P_INS_EDGE_S1S2_EVAL =>
            ins_es1s2_pre  <= edge_rdata;
            ins_es1s2_addr <= edge_raddr;
            if edge_rdata /= x"00" then
              ph <= P_INS_EDGE_S1S2_CLR_WR;
            else
              ph <= P_INS_S2_RD;
            end if;

          when P_INS_EDGE_S1S2_CLR_WR =>
            edge_we <= '1';
            edge_waddr <= ins_es1s2_addr;
            edge_wdata <= x"00";
            ph <= P_INS_S2_RD;

          when P_INS_S2_RD =>
            node_raddr <= s2_id;
            ph <= P_INS_S2_WAIT;

          when P_INS_S2_WAIT =>
            ph <= P_INS_NODE_WR;

          when P_INS_NODE_WR =>
            w := node_rdata;

            sumx := resize(dbg_s1x,17) + resize(get_x(w),17);
            sumy := resize(dbg_s1y,17) + resize(get_y(w),17);
            rx := shift_right(sumx, 1);
            ry := shift_right(sumy, 1);

            node_we <= '1';
            node_waddr <= to_unsigned(ins_free,8);
            node_wdata <= pack_node(sat_s16(resize(rx,18)), sat_s16(resize(ry,18)), '1', to_unsigned(2,8), s1_err_reg);

            ins_flag <= '1';
            ins_id_dbg <= to_unsigned(ins_free,8);

            if node_count < to_unsigned(MAX_NODES,8) then
              node_count <= node_count + 1;
            end if;

            ph <= P_INS_EDGE1_WR;

          when P_INS_EDGE1_WR =>
            i1 := to_integer(s1_id);
            i2 := ins_free;
            if i1 < i2 then idxe := edge_idx(i1,i2,MAX_NODES);
            else idxe := edge_idx(i2,i1,MAX_NODES);
            end if;
            edge_we <= '1';
            edge_waddr <= to_unsigned(idxe, 13);
            edge_wdata <= x"01";
            ph <= P_INS_EDGE2_WR;

          when P_INS_EDGE2_WR =>
            i1 := ins_free;
            i2 := to_integer(s2_id);
            if i1 < i2 then idxe := edge_idx(i1,i2,MAX_NODES);
            else idxe := edge_idx(i2,i1,MAX_NODES);
            end if;
            edge_we <= '1';
            edge_waddr <= to_unsigned(idxe, 13);
            edge_wdata <= x"01";

            if ins_es1s2_pre = x"00" then
              ph <= P_INS_DEG_S1_RD;
            else
              ph <= P_DBG_EDGE01_REQ;
            end if;

          when P_INS_DEG_S1_RD =>
            node_raddr <= s1_id;
            ph <= P_INS_DEG_S1_WAIT;

          when P_INS_DEG_S1_WAIT =>
            ph <= P_INS_DEG_S1_WR;

          when P_INS_DEG_S1_WR =>
            w := node_rdata;
            act := get_act(w);
            deg := get_deg(w);
            if act='1' then
              if deg < to_unsigned(255,8) then deg := deg + 1; end if;
              node_we <= '1';
              node_waddr <= s1_id;
              node_wdata <= pack_node(get_x(w), get_y(w), act, deg, get_err(w));
            end if;
            ph <= P_INS_DEG_S2_RD;

          when P_INS_DEG_S2_RD =>
            node_raddr <= s2_id;
            ph <= P_INS_DEG_S2_WAIT;

          when P_INS_DEG_S2_WAIT =>
            ph <= P_INS_DEG_S2_WR;

          when P_INS_DEG_S2_WR =>
            w := node_rdata;
            act := get_act(w);
            deg := get_deg(w);
            if act='1' then
              if deg < to_unsigned(255,8) then deg := deg + 1; end if;
              node_we <= '1';
              node_waddr <= s2_id;
              node_wdata <= pack_node(get_x(w), get_y(w), act, deg, get_err(w));
            end if;
            ph <= P_DBG_EDGE01_REQ;

          when P_DBG_EDGE01_REQ =>
            idxe := edge_idx(0,1,MAX_NODES);
            edge_raddr <= to_unsigned(idxe, 13);
            ph <= P_DBG_EDGE01_WAIT;

          when P_DBG_EDGE01_WAIT =>
            ph <= P_DBG_EDGE01_EVAL;

          when P_DBG_EDGE01_EVAL =>
            dbg_e01 <= edge_rdata;
            ph <= P_DBG_DEG_S1_RD;

          when P_DBG_DEG_S1_RD =>
            node_raddr <= s1_id;
            ph <= P_DBG_DEG_S1_WAIT;

          when P_DBG_DEG_S1_WAIT =>
            ph <= P_DBG_DEG_S1_EVAL;

          when P_DBG_DEG_S1_EVAL =>
            dbg_deg_s1 <= get_deg(node_rdata);
            ph <= P_DBG_DEG_S2_RD;

          when P_DBG_DEG_S2_RD =>
            node_raddr <= s2_id;
            ph <= P_DBG_DEG_S2_WAIT;

          when P_DBG_DEG_S2_WAIT =>
            ph <= P_DBG_DEG_S2_EVAL;

          when P_DBG_DEG_S2_EVAL =>
            dbg_deg_s2 <= get_deg(node_rdata);
            ph <= P_TX_PREP;

          when P_TX_PREP =>
            tx_buf(0)  <= B_A5; tx_buf(1) <= x"10";
            tx_buf(2)  <= B_A6; tx_buf(3) <= std_logic_vector(s1_id);
            tx_buf(4)  <= B_A7; tx_buf(5) <= std_logic_vector(s2_id);
            tx_buf(6)  <= B_A8; tx_buf(7) <= dbg_e01;

            tx_buf(8)  <= B_C0; tx_buf(9)  <= dbg_es1s2_pre;
            tx_buf(10) <= B_C1; tx_buf(11) <= std_logic_vector(dbg_deg_s1);
            tx_buf(12) <= B_C2; tx_buf(13) <= std_logic_vector(dbg_deg_s2);

            tx_buf(14) <= B_C3; tx_buf(15) <= (others=>'0'); tx_buf(15)(0) <= s2_valid;
            tx_buf(16) <= B_C4; tx_buf(17) <= (others=>'0'); tx_buf(17)(0) <= rm_flag;
            tx_buf(18) <= B_C5; tx_buf(19) <= (others=>'0'); tx_buf(19)(0) <= iso_flag;
            tx_buf(20) <= B_C6; tx_buf(21) <= std_logic_vector(iso_id_dbg);
            tx_buf(22) <= B_C7; tx_buf(23) <= std_logic_vector(node_count);
            tx_buf(24) <= B_C8; tx_buf(25) <= (others=>'0'); tx_buf(25)(0) <= ins_flag;
            tx_buf(26) <= B_C9; tx_buf(27) <= std_logic_vector(ins_id_dbg);

            tx_buf(28) <= B_AA; tx_buf(29) <= std_logic_vector(dbg_err32(7 downto 0));
            tx_buf(30) <= B_AB; tx_buf(31) <= std_logic_vector(dbg_err32(15 downto 8));
            tx_buf(32) <= B_AC; tx_buf(33) <= std_logic_vector(dbg_err32(23 downto 16));
            tx_buf(34) <= B_AD; tx_buf(35) <= std_logic_vector(dbg_err32(31 downto 24));

            tx_buf(36) <= B_AE; tx_buf(37) <= std_logic_vector(dbg_s1x(7 downto 0));
            tx_buf(38) <= B_AF; tx_buf(39) <= std_logic_vector(dbg_s1x(15 downto 8));

            tx_buf(40) <= B_B0; tx_buf(41) <= std_logic_vector(dbg_s1y(7 downto 0));
            tx_buf(42) <= B_B1; tx_buf(43) <= std_logic_vector(dbg_s1y(15 downto 8));

            tx_buf(44) <= B_A9; tx_buf(45) <= std_logic_vector(to_unsigned(samp_i mod 256, 8));

            tx_len <= 46;
            tx_idx <= 0;
            ph <= P_TX_SEND;

          when P_TX_SEND =>
            if (tx_busy_i='0') and (tx_inflight='0') then
              tx_start_o <= '1';
              tx_data_o  <= tx_buf(tx_idx);
              tx_inflight <= '1';
              ph <= P_TX_WAIT;
            end if;

          when P_TX_WAIT =>
            if (tx_done_i='1') or (tx_inflight='0') then
              if tx_idx = tx_len-1 then
                done_p <= '1';
                ph <= P_NEXT;
              else
                tx_idx <= tx_idx + 1;
                ph <= P_TX_SEND;
              end if;
            end if;

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
