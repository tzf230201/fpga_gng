library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng is
  generic (
    MAX_NODES        : natural := 40;  -- <= 64
    MAX_DEG          : natural := 6;
    A_MAX            : natural := 100;

    DATA_WORDS       : natural := 100; -- dataset size (word32)
    DONE_EVERY_STEPS : natural := 20;  -- pulse gng_done tiap N step

    LAMBDA_STEPS     : natural := 50;  -- INSERT setiap 50 step
    ALPHA_SHIFT      : natural := 1;   -- q,f error *= 1/2^ALPHA_SHIFT saat insert

    -- Fritzke global error decay: E <- E - (E >> BETA_SHIFT)
    BETA_SHIFT       : natural := 8;

    -- init nodes (x,y) integer
    INIT_X0          : integer := 200;
    INIT_Y0          : integer := 200;
    INIT_X1          : integer := 800;
    INIT_Y1          : integer := 800;

    -- learning rates = 1/2^shift
    LEARN_SHIFT      : natural := 4;   -- winner update
    NB_LEARN_SHIFT   : natural := 6    -- neighbor update
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in  std_logic;

    -- dataset word32, sync read 1-cycle
    data_raddr_o : out unsigned(6 downto 0);
    data_rdata_i : in  std_logic_vector(31 downto 0);

    gng_done_o : out std_logic;
    gng_busy_o : out std_logic;

    s1_id_o : out unsigned(5 downto 0);
    s2_id_o : out unsigned(5 downto 0);

    -- debug read taps (sync 1-cycle)
    dbg_node_raddr_i : in  unsigned(5 downto 0);
    dbg_node_rdata_o : out std_logic_vector(31 downto 0);

    dbg_err_raddr_i  : in  unsigned(5 downto 0);
    dbg_err_rdata_o  : out std_logic_vector(31 downto 0);

    dbg_edge_raddr_i : in  unsigned(8 downto 0);
    dbg_edge_rdata_o : out std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of gng is

  -- ============================================================
  -- helpers
  -- ============================================================
  function abs_i(v : integer) return integer is
  begin
    if v < 0 then return -v; else return v; end if;
  end function;

  function sat16(v : integer) return integer is
  begin
    if v > 32767 then
      return 32767;
    elsif v < -32768 then
      return -32768;
    else
      return v;
    end if;
  end function;

  function clog2(n : natural) return natural is
    variable r : natural := 0;
    variable v : natural := 1;
  begin
    while v < n loop
      v := v * 2;
      r := r + 1;
    end loop;
    return r;
  end function;

  -- ============================================================
  -- constants / subtypes (FIX Gowin EX4762)
  -- ============================================================
  constant EDGE_DEPTH : natural := MAX_NODES * MAX_DEG;
  constant EDGE_AW    : natural := clog2(EDGE_DEPTH); -- 240 -> 8

  subtype u8_t       is unsigned(7 downto 0);
  subtype u6_t       is unsigned(5 downto 0);
  subtype u31_t      is unsigned(30 downto 0);
  subtype slv16_t    is std_logic_vector(15 downto 0);
  subtype slv32_t    is std_logic_vector(31 downto 0);
  subtype edge_addr_t is unsigned(EDGE_AW-1 downto 0);

  constant ZERO31    : u31_t := (others => '0');
  constant U31_MAX   : u31_t := (others => '1');
  constant SLOT_NONE : integer := 255;

  -- ============================================================
  -- edge address + packing helpers
  -- ============================================================
  function edge_addr(node_id : u6_t; slot : integer) return edge_addr_t is
    variable base : integer;
  begin
    base := to_integer(node_id) * integer(MAX_DEG);
    return to_unsigned(base + slot, EDGE_AW);
  end function;

  function edge_valid(w : slv16_t) return std_logic is
  begin
    return w(15);
  end function;

  function edge_age(w : slv16_t) return u8_t is
    variable a : u8_t;
  begin
    a := unsigned(w(14 downto 7));
    return a;
  end function;

  function edge_nb(w : slv16_t) return u6_t is
    variable n : u6_t;
  begin
    n := unsigned(w(6 downto 1));
    return n;
  end function;

  function make_edge(vld : std_logic; age : u8_t; nb : u6_t) return slv16_t is
    variable r : slv16_t := (others => '0');
  begin
    r(15) := vld;
    r(14 downto 7) := std_logic_vector(age);
    r(6 downto 1)  := std_logic_vector(nb);
    r(0) := '0';
    return r;
  end function;

  function is_active(e : slv32_t) return boolean is
  begin
    return (e(31) = '1');
  end function;

  function get_err(e : slv32_t) return u31_t is
    variable v : u31_t;
  begin
    v := unsigned(e(30 downto 0));
    return v;
  end function;

  function pack_err(active : std_logic; val : u31_t) return slv32_t is
    variable r : slv32_t := (others => '0');
  begin
    r(31) := active;
    r(30 downto 0) := std_logic_vector(val);
    return r;
  end function;

  -- ============================================================
  -- BRAM-style memories
  -- ============================================================
  -- node_mem[i] : [31:16]=y(s16), [15:0]=x(s16)
  type node_mem_t is array (0 to MAX_NODES-1) of slv32_t;
  signal node_mem  : node_mem_t := (others => (others => '0'));
  signal node_raddr : u6_t := (others => '0');
  signal node_rdata : slv32_t := (others => '0');
  signal node_we    : std_logic := '0';
  signal node_waddr : u6_t := (others => '0');
  signal node_wdata : slv32_t := (others => '0');

  -- err_mem[i] : bit31=active, bits30..0=unsigned error
  type err_mem_t is array (0 to MAX_NODES-1) of slv32_t;
  signal err_mem   : err_mem_t := (others => (others => '0'));
  signal err_raddr : u6_t := (others => '0');
  signal err_rdata : slv32_t := (others => '0');
  signal err_we    : std_logic := '0';
  signal err_waddr : u6_t := (others => '0');
  signal err_wdata : slv32_t := (others => '0');

  -- edge_mem slot: 16-bit
  -- [15]=valid, [14:7]=age(8), [6:1]=nb_id(6), [0]=0
  type edge_mem_t is array (0 to EDGE_DEPTH-1) of slv16_t;
  signal edge_mem   : edge_mem_t := (others => (others => '0'));
  signal edge_raddr : edge_addr_t := (others => '0');
  signal edge_rdata : slv16_t := (others => '0');
  signal edge_we    : std_logic := '0';
  signal edge_waddr : edge_addr_t := (others => '0');
  signal edge_wdata : slv16_t := (others => '0');

  attribute ram_style : string;
  attribute ram_style of node_mem : signal is "block";
  attribute ram_style of err_mem  : signal is "block";
  attribute ram_style of edge_mem : signal is "block";

  -- ============================================================
  -- FSM
  -- ============================================================
  type st_t is (
    ST_IDLE,

    -- init nodes + clear edges
    ST_INIT_N_SET, ST_INIT_N_WAIT,
    ST_INIT_E_SET, ST_INIT_E_WAIT,

    -- read dataset word32
    ST_DATA_SET, ST_DATA_WAIT, ST_DATA_LATCH,

    -- find winners (s1,s2) - Manhattan distance
    ST_FIND_SET, ST_FIND_WAIT, ST_FIND_EVAL,

    -- age/prune edges of s1
    ST_AGE_SET, ST_AGE_WAIT, ST_AGE_LATCH,

    -- remove reciprocal edge in rm_nb
    ST_RM_SET, ST_RM_WAIT, ST_RM_LATCH,

    -- connect s1<->s2
    ST_CONN_S1_SET, ST_CONN_S1_WAIT, ST_CONN_S1_LATCH,
    ST_CONN_S2_SET, ST_CONN_S2_WAIT, ST_CONN_S2_LATCH,
    ST_CONN_W1, ST_CONN_W2,

    -- update s1 node + error
    ST_UPD_S1_SET, ST_UPD_S1_WAIT, ST_UPD_S1_LATCH,

    -- update neighbors of s1
    ST_NB_EDGE_SET, ST_NB_EDGE_WAIT, ST_NB_EDGE_LATCH,
    ST_NB_NODE_WAIT, ST_NB_NODE_LATCH,
    ST_NB_NODE_WR,

    -- check isolated s1
    ST_ISO_S1_SET, ST_ISO_S1_WAIT, ST_ISO_S1_LATCH,

    -- common disable+clear edges
    ST_DISABLE_ERR,
    ST_DISABLE_CLR,

    -- maybe insert
    ST_MAY_INSERT,

    -- INSERT pipeline (lambda)
    ST_INS_Q_SET, ST_INS_Q_WAIT, ST_INS_Q_EVAL,
    ST_INS_F_EDGE_SET, ST_INS_F_EDGE_WAIT, ST_INS_F_EDGE_LATCH,
    ST_INS_F_ERR_WAIT,  ST_INS_F_ERR_LATCH,
    ST_INS_FREE_SET, ST_INS_FREE_WAIT, ST_INS_FREE_EVAL,
    ST_INS_RDQ_SET, ST_INS_RDQ_WAIT, ST_INS_RDQ_LATCH,
    ST_INS_RDF_SET, ST_INS_RDF_WAIT, ST_INS_RDF_LATCH,
    ST_INS_WR_R,
    ST_INS_WR_QERR,
    ST_INS_WR_FERR,
    ST_INS_WR_QEDGE,
    ST_INS_FIND_FQ_SET, ST_INS_FIND_FQ_WAIT, ST_INS_FIND_FQ_LATCH,
    ST_INS_WR_FEDGE,
    ST_INS_WR_REDGE0,
    ST_INS_WR_REDGE1,

    -- Fritzke error decay for all nodes
    ST_EDEC_SET, ST_EDEC_WAIT, ST_EDEC_LATCH,

    -- next / done
    ST_NEXT,
    ST_DONE
  );

  signal st     : st_t := ST_IDLE;
  signal ret_st : st_t := ST_IDLE;

  -- start pulse
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  -- init counters
  signal inited      : std_logic := '0';
  signal init_i      : u6_t := (others => '0');
  signal init_edge_i : edge_addr_t := (others => '0');

  -- dataset
  signal sample_idx : unsigned(6 downto 0) := (others => '0');
  signal sx_i, sy_i : integer := 0;

  -- batch step counter for done pulse
  signal steps_left : integer := 0;

  -- lambda counter (mod LAMBDA_STEPS)
  signal lambda_cnt : integer range 0 to integer(LAMBDA_STEPS-1) := 0;

  -- find winners
  signal node_idx : u6_t := (others => '0');
  signal best1    : integer := 2147483647;
  signal best2    : integer := 2147483647;
  signal s1_id    : u6_t := (others => '0');
  signal s2_id    : u6_t := (others => '0');

  -- loops / temps
  signal k_slot    : integer range 0 to 255 := 0;
  signal rm_k      : integer range 0 to 255 := 0;
  signal nb_slot   : integer range 0 to 255 := 0;
  signal iso_slot  : integer range 0 to 255 := 0;

  signal rm_nb        : u6_t := (others => '0');
  signal rm_has_edge  : std_logic := '0';
  signal iso_has_edge : std_logic := '0';

  -- connect bookkeeping
  signal c_found1 : std_logic := '0';
  signal c_found2 : std_logic := '0';
  signal c_slot1  : integer range 0 to 255 := 0;
  signal c_slot2  : integer range 0 to 255 := 0;
  signal c_empty1 : integer range 0 to 255 := 0;
  signal c_empty2 : integer range 0 to 255 := 0;

  -- neighbor temp
  signal nb_id : u6_t := (others => '0');

  -- disable target
  signal dis_id   : u6_t := (others => '0');
  signal dis_slot : integer range 0 to 255 := 0;

  -- INSERT temp
  signal ins_scan_id : u6_t := (others => '0');

  signal q_id    : u6_t := (others => '0');
  signal f_id    : u6_t := (others => '0');
  signal r_id    : u6_t := (others => '0');

  signal q_err_max : u31_t := (others => '0');
  signal f_err_max : u31_t := (others => '0');

  signal f_slot_q : integer range 0 to 255 := 0; -- slot in q that points to f
  signal f_found  : std_logic := '0';

  signal free_found : std_logic := '0';

  signal qx_i, qy_i : integer := 0;
  signal fx_i, fy_i : integer := 0;

  signal fq_slot_f : integer range 0 to 255 := 0; -- slot in f that points to q
  signal fq_found  : std_logic := '0';

  -- error decay scan id
  signal edec_id : u6_t := (others => '0');

  signal done_pulse : std_logic := '0';

begin
  data_raddr_o <= sample_idx;

  gng_done_o <= done_pulse;
  gng_busy_o <= '0' when st = ST_IDLE else '1';

  s1_id_o <= s1_id;
  s2_id_o <= s2_id;

  -- start edge detect
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        start_d <= '0';
        start_p <= '0';
      else
        start_p <= start_i and (not start_d);
        start_d <= start_i;
      end if;
    end if;
  end process;

  -- ============================================================
  -- RAMs sync write + sync read ( + debug taps )
  -- ============================================================
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if node_we = '1' then
        node_mem(to_integer(node_waddr)) <= node_wdata;
      end if;
      node_rdata <= node_mem(to_integer(node_raddr));

      if err_we = '1' then
        err_mem(to_integer(err_waddr)) <= err_wdata;
      end if;
      err_rdata <= err_mem(to_integer(err_raddr));

      if edge_we = '1' then
        edge_mem(to_integer(edge_waddr)) <= edge_wdata;
      end if;
      edge_rdata <= edge_mem(to_integer(edge_raddr));

      -- debug read taps (slice address)
      dbg_node_rdata_o <= node_mem(to_integer(dbg_node_raddr_i));
      dbg_err_rdata_o  <= err_mem(to_integer(dbg_err_raddr_i));
      dbg_edge_rdata_o <= edge_mem(to_integer(dbg_edge_raddr_i(EDGE_AW-1 downto 0)));
    end if;
  end process;

  -- ============================================================
  -- MAIN FSM
  -- ============================================================
  process(clk_i)
    variable xi, yi : integer;
    variable wx, wy : integer;
    variable dx, dy : integer;
    variable dist   : integer;

    variable ew     : slv16_t;
    variable vld    : std_logic;
    variable age    : u8_t;
    variable nb     : u6_t;

    variable err_u  : u31_t;
    variable err_n  : u31_t;
    variable dist_u : u31_t;

    variable upd    : integer;

    variable rm_has_edge_now  : std_logic;
    variable iso_has_edge_now : std_logic;

    variable qx, qy, fx, fy : integer;
    variable rx, ry : integer;

    variable old_q_err : u31_t;
    variable new_q_err : u31_t;
    variable new_f_err : u31_t;

    variable found_slot_local : std_logic;

    variable dec_tmp : u31_t;
  begin
    if rising_edge(clk_i) then
      done_pulse <= '0';

      node_we <= '0';
      err_we  <= '0';
      edge_we <= '0';

      if rstn_i = '0' then
        st <= ST_IDLE;

        inited      <= '0';
        init_i      <= (others => '0');
        init_edge_i <= (others => '0');

        sample_idx  <= (others => '0');
        sx_i <= 0; sy_i <= 0;
        steps_left  <= 0;

        lambda_cnt <= 0;

        node_idx <= (others => '0');
        best1    <= 2147483647;
        best2    <= 2147483647;
        s1_id    <= (others => '0');
        s2_id    <= (others => '0');

        k_slot <= 0;
        rm_k   <= 0;
        rm_nb  <= (others => '0');
        rm_has_edge <= '0';

        nb_slot <= 0;
        nb_id   <= (others => '0');

        iso_slot <= 0;
        iso_has_edge <= '0';

        dis_id   <= (others => '0');
        dis_slot <= 0;
        ret_st   <= ST_IDLE;

        c_found1 <= '0'; c_found2 <= '0';
        c_empty1 <= SLOT_NONE; c_empty2 <= SLOT_NONE;
        c_slot1  <= SLOT_NONE; c_slot2  <= SLOT_NONE;

        ins_scan_id <= (others => '0');
        q_id <= (others => '0');
        f_id <= (others => '0');
        r_id <= (others => '0');
        q_err_max <= (others => '0');
        f_err_max <= (others => '0');
        f_slot_q <= 0;
        f_found  <= '0';
        free_found <= '0';
        qx_i <= 0; qy_i <= 0;
        fx_i <= 0; fy_i <= 0;
        fq_slot_f <= 0;
        fq_found  <= '0';

        edec_id <= (others => '0');

      else
        case st is

          -- ======================================================
          -- IDLE / START
          -- ======================================================
          when ST_IDLE =>
            if start_p = '1' then
              steps_left <= integer(DONE_EVERY_STEPS);

              if inited = '0' then
                init_i <= (others => '0');
                st <= ST_INIT_N_SET;
              else
                st <= ST_DATA_SET;
              end if;
            end if;

          -- ======================================================
          -- INIT NODES
          -- ======================================================
          when ST_INIT_N_SET =>
            node_waddr <= init_i;
            err_waddr  <= init_i;

            if init_i = to_unsigned(0, 6) then
              node_wdata <= std_logic_vector(to_signed(INIT_Y0,16)) & std_logic_vector(to_signed(INIT_X0,16));
              err_wdata  <= pack_err('1', ZERO31);
            elsif init_i = to_unsigned(1, 6) then
              node_wdata <= std_logic_vector(to_signed(INIT_Y1,16)) & std_logic_vector(to_signed(INIT_X1,16));
              err_wdata  <= pack_err('1', ZERO31);
            else
              node_wdata <= (others => '0');
              err_wdata  <= pack_err('0', ZERO31);
            end if;

            node_we <= '1';
            err_we  <= '1';
            st <= ST_INIT_N_WAIT;

          when ST_INIT_N_WAIT =>
            if init_i = to_unsigned(MAX_NODES-1, 6) then
              init_edge_i <= (others => '0');
              st <= ST_INIT_E_SET;
            else
              init_i <= init_i + 1;
              st <= ST_INIT_N_SET;
            end if;

          -- ======================================================
          -- INIT EDGES (clear all)
          -- ======================================================
          when ST_INIT_E_SET =>
            edge_waddr <= init_edge_i;
            edge_wdata <= make_edge('0', (others => '0'), (others => '0'));
            edge_we <= '1';
            st <= ST_INIT_E_WAIT;

          when ST_INIT_E_WAIT =>
            if init_edge_i = to_unsigned(EDGE_DEPTH-1, EDGE_AW) then
              inited <= '1';
              sample_idx <= (others => '0');
              lambda_cnt <= 0;
              st <= ST_DATA_SET;
            else
              init_edge_i <= init_edge_i + 1;
              st <= ST_INIT_E_SET;
            end if;

          -- ======================================================
          -- READ dataset word32 (sync)
          -- ======================================================
          when ST_DATA_SET =>
            st <= ST_DATA_WAIT;

          when ST_DATA_WAIT =>
            st <= ST_DATA_LATCH;

          when ST_DATA_LATCH =>
            xi := to_integer(signed(data_rdata_i(15 downto 0)));
            yi := to_integer(signed(data_rdata_i(31 downto 16)));
            sx_i <= xi;
            sy_i <= yi;

            node_idx <= (others => '0');
            best1 <= 2147483647;
            best2 <= 2147483647;
            s1_id <= (others => '0');
            s2_id <= (others => '0');

            st <= ST_FIND_SET;

          -- ======================================================
          -- FIND WINNERS (Manhattan)
          -- ======================================================
          when ST_FIND_SET =>
            node_raddr <= node_idx;
            err_raddr  <= node_idx;
            st <= ST_FIND_WAIT;

          when ST_FIND_WAIT =>
            st <= ST_FIND_EVAL;

          when ST_FIND_EVAL =>
            if is_active(err_rdata) then
              wx := to_integer(signed(node_rdata(15 downto 0)));
              wy := to_integer(signed(node_rdata(31 downto 16)));
              dx := sx_i - wx;
              dy := sy_i - wy;

              dist := abs_i(dx) + abs_i(dy);

              if dist < best1 then
                best2 <= best1;
                s2_id <= s1_id;
                best1 <= dist;
                s1_id <= node_idx;
              elsif dist < best2 then
                if node_idx /= s1_id then
                  best2 <= dist;
                  s2_id <= node_idx;
                end if;
              end if;
            end if;

            if node_idx = to_unsigned(MAX_NODES-1, 6) then
              k_slot <= 0;
              st <= ST_AGE_SET;
            else
              node_idx <= node_idx + 1;
              st <= ST_FIND_SET;
            end if;

          -- ======================================================
          -- EDGE AGING / PRUNE for s1
          -- ======================================================
          when ST_AGE_SET =>
            edge_raddr <= edge_addr(s1_id, k_slot);
            st <= ST_AGE_WAIT;

          when ST_AGE_WAIT =>
            st <= ST_AGE_LATCH;

          when ST_AGE_LATCH =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            age := edge_age(ew);
            nb  := edge_nb(ew);

            if vld = '1' then
              if age /= to_unsigned(255, 8) then
                age := age + 1;
              end if;

              if to_integer(age) > integer(A_MAX) then
                edge_waddr <= edge_addr(s1_id, k_slot);
                edge_wdata <= make_edge('0', (others => '0'), (others => '0'));
                edge_we <= '1';

                rm_nb <= nb;
                rm_k  <= 0;
                rm_has_edge <= '0';
                st <= ST_RM_SET;

              else
                edge_waddr <= edge_addr(s1_id, k_slot);
                edge_wdata <= make_edge('1', age, nb);
                edge_we <= '1';

                if k_slot = integer(MAX_DEG-1) then
                  c_found1 <= '0'; c_found2 <= '0';
                  c_empty1 <= SLOT_NONE; c_empty2 <= SLOT_NONE;
                  c_slot1  <= SLOT_NONE; c_slot2  <= SLOT_NONE;
                  k_slot   <= 0;
                  st <= ST_CONN_S1_SET;
                else
                  k_slot <= k_slot + 1;
                  st <= ST_AGE_SET;
                end if;
              end if;

            else
              if k_slot = integer(MAX_DEG-1) then
                c_found1 <= '0'; c_found2 <= '0';
                c_empty1 <= SLOT_NONE; c_empty2 <= SLOT_NONE;
                c_slot1  <= SLOT_NONE; c_slot2  <= SLOT_NONE;
                k_slot   <= 0;
                st <= ST_CONN_S1_SET;
              else
                k_slot <= k_slot + 1;
                st <= ST_AGE_SET;
              end if;
            end if;

          -- ======================================================
          -- REMOVE reciprocal in rm_nb, disable if isolated
          -- ======================================================
          when ST_RM_SET =>
            edge_raddr <= edge_addr(rm_nb, rm_k);
            st <= ST_RM_WAIT;

          when ST_RM_WAIT =>
            st <= ST_RM_LATCH;

          when ST_RM_LATCH =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            nb  := edge_nb(ew);

            rm_has_edge_now := rm_has_edge;

            if (vld = '1') and (nb /= s1_id) then
              rm_has_edge_now := '1';
            end if;

            if (vld = '1') and (nb = s1_id) then
              edge_waddr <= edge_addr(rm_nb, rm_k);
              edge_wdata <= make_edge('0', (others => '0'), (others => '0'));
              edge_we <= '1';
            end if;

            rm_has_edge <= rm_has_edge_now;

            if rm_k = integer(MAX_DEG-1) then
              if rm_has_edge_now = '0' then
                dis_id   <= rm_nb;
                dis_slot <= 0;
                ret_st   <= ST_AGE_SET;
                st <= ST_DISABLE_ERR;
              else
                if k_slot = integer(MAX_DEG-1) then
                  c_found1 <= '0'; c_found2 <= '0';
                  c_empty1 <= SLOT_NONE; c_empty2 <= SLOT_NONE;
                  c_slot1  <= SLOT_NONE; c_slot2  <= SLOT_NONE;
                  k_slot   <= 0;
                  st <= ST_CONN_S1_SET;
                else
                  k_slot <= k_slot + 1;
                  st <= ST_AGE_SET;
                end if;
              end if;
            else
              rm_k <= rm_k + 1;
              st <= ST_RM_SET;
            end if;

          -- ======================================================
          -- CONNECT scan s1
          -- ======================================================
          when ST_CONN_S1_SET =>
            edge_raddr <= edge_addr(s1_id, k_slot);
            st <= ST_CONN_S1_WAIT;

          when ST_CONN_S1_WAIT =>
            st <= ST_CONN_S1_LATCH;

          when ST_CONN_S1_LATCH =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            nb  := edge_nb(ew);

            if (vld = '1') and (nb = s2_id) then
              c_found1 <= '1';
              c_slot1  <= k_slot;
            elsif (vld = '0') and (c_empty1 = SLOT_NONE) then
              c_empty1 <= k_slot;
            end if;

            if k_slot = integer(MAX_DEG-1) then
              k_slot <= 0;
              st <= ST_CONN_S2_SET;
            else
              k_slot <= k_slot + 1;
              st <= ST_CONN_S1_SET;
            end if;

          -- ======================================================
          -- CONNECT scan s2
          -- ======================================================
          when ST_CONN_S2_SET =>
            edge_raddr <= edge_addr(s2_id, k_slot);
            st <= ST_CONN_S2_WAIT;

          when ST_CONN_S2_WAIT =>
            st <= ST_CONN_S2_LATCH;

          when ST_CONN_S2_LATCH =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            nb  := edge_nb(ew);

            if (vld = '1') and (nb = s1_id) then
              c_found2 <= '1';
              c_slot2  <= k_slot;
            elsif (vld = '0') and (c_empty2 = SLOT_NONE) then
              c_empty2 <= k_slot;
            end if;

            if k_slot = integer(MAX_DEG-1) then
              st <= ST_CONN_W1;
            else
              k_slot <= k_slot + 1;
              st <= ST_CONN_S2_SET;
            end if;

          when ST_CONN_W1 =>
            if c_found1 = '1' then
              edge_waddr <= edge_addr(s1_id, c_slot1);
              edge_wdata <= make_edge('1', (others => '0'), s2_id);
              edge_we <= '1';
            elsif (c_empty1 /= SLOT_NONE) and (c_empty2 /= SLOT_NONE) then
              edge_waddr <= edge_addr(s1_id, c_empty1);
              edge_wdata <= make_edge('1', (others => '0'), s2_id);
              edge_we <= '1';
            end if;
            st <= ST_CONN_W2;

          when ST_CONN_W2 =>
            if c_found2 = '1' then
              edge_waddr <= edge_addr(s2_id, c_slot2);
              edge_wdata <= make_edge('1', (others => '0'), s1_id);
              edge_we <= '1';
            elsif (c_empty1 /= SLOT_NONE) and (c_empty2 /= SLOT_NONE) then
              edge_waddr <= edge_addr(s2_id, c_empty2);
              edge_wdata <= make_edge('1', (others => '0'), s1_id);
              edge_we <= '1';
            end if;
            st <= ST_UPD_S1_SET;

          -- ======================================================
          -- UPDATE S1 node + error
          -- ======================================================
          when ST_UPD_S1_SET =>
            node_raddr <= s1_id;
            err_raddr  <= s1_id;
            st <= ST_UPD_S1_WAIT;

          when ST_UPD_S1_WAIT =>
            st <= ST_UPD_S1_LATCH;

          when ST_UPD_S1_LATCH =>
            wx := to_integer(signed(node_rdata(15 downto 0)));
            wy := to_integer(signed(node_rdata(31 downto 16)));

            dx := sx_i - wx;
            dy := sy_i - wy;

            upd := dx / (2**integer(LEARN_SHIFT));
            wx := sat16(wx + upd);

            upd := dy / (2**integer(LEARN_SHIFT));
            wy := sat16(wy + upd);

            node_waddr <= s1_id;
            node_wdata <= std_logic_vector(to_signed(wy,16)) & std_logic_vector(to_signed(wx,16));
            node_we <= '1';

            -- accumulate error s1 (saturate 31-bit)
            err_u  := get_err(err_rdata);
            dist_u := to_unsigned(best1, 31);

            if err_u > (U31_MAX - dist_u) then
              err_n := U31_MAX;
            else
              err_n := err_u + dist_u;
            end if;

            err_waddr <= s1_id;
            err_wdata <= pack_err('1', err_n);
            err_we <= '1';

            nb_slot <= 0;
            st <= ST_NB_EDGE_SET;

          -- ======================================================
          -- UPDATE NEIGHBORS of s1
          -- ======================================================
          when ST_NB_EDGE_SET =>
            if nb_slot >= integer(MAX_DEG) then
              iso_slot <= 0;
              iso_has_edge <= '0';
              st <= ST_ISO_S1_SET;
            else
              edge_raddr <= edge_addr(s1_id, nb_slot);
              st <= ST_NB_EDGE_WAIT;
            end if;

          when ST_NB_EDGE_WAIT =>
            st <= ST_NB_EDGE_LATCH;

          when ST_NB_EDGE_LATCH =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            nb  := edge_nb(ew);

            if vld = '1' then
              nb_id <= nb;
              node_raddr <= nb;
              st <= ST_NB_NODE_WAIT;
            else
              nb_slot <= nb_slot + 1;
              st <= ST_NB_EDGE_SET;
            end if;

          when ST_NB_NODE_WAIT =>
            st <= ST_NB_NODE_LATCH;

          when ST_NB_NODE_LATCH =>
            wx := to_integer(signed(node_rdata(15 downto 0)));
            wy := to_integer(signed(node_rdata(31 downto 16)));

            dx := sx_i - wx;
            dy := sy_i - wy;

            upd := dx / (2**integer(NB_LEARN_SHIFT));
            wx := sat16(wx + upd);

            upd := dy / (2**integer(NB_LEARN_SHIFT));
            wy := sat16(wy + upd);

            node_waddr <= nb_id;
            node_wdata <= std_logic_vector(to_signed(wy,16)) & std_logic_vector(to_signed(wx,16));
            node_we <= '1';

            st <= ST_NB_NODE_WR;

          when ST_NB_NODE_WR =>
            nb_slot <= nb_slot + 1;
            st <= ST_NB_EDGE_SET;

          -- ======================================================
          -- CHECK ISOLATED S1
          -- ======================================================
          when ST_ISO_S1_SET =>
            edge_raddr <= edge_addr(s1_id, iso_slot);
            st <= ST_ISO_S1_WAIT;

          when ST_ISO_S1_WAIT =>
            st <= ST_ISO_S1_LATCH;

          when ST_ISO_S1_LATCH =>
            ew  := edge_rdata;
            vld := edge_valid(ew);

            iso_has_edge_now := iso_has_edge;
            if vld = '1' then
              iso_has_edge_now := '1';
            end if;
            iso_has_edge <= iso_has_edge_now;

            if iso_slot = integer(MAX_DEG-1) then
              if iso_has_edge_now = '0' then
                dis_id   <= s1_id;
                dis_slot <= 0;
                ret_st   <= ST_MAY_INSERT;
                st <= ST_DISABLE_ERR;
              else
                st <= ST_MAY_INSERT;
              end if;
            else
              iso_slot <= iso_slot + 1;
              st <= ST_ISO_S1_SET;
            end if;

          -- ======================================================
          -- COMMON DISABLE + CLEAR
          -- ======================================================
          when ST_DISABLE_ERR =>
            err_waddr <= dis_id;
            err_wdata <= pack_err('0', ZERO31);
            err_we <= '1';
            dis_slot <= 0;
            st <= ST_DISABLE_CLR;

          when ST_DISABLE_CLR =>
            edge_waddr <= edge_addr(dis_id, dis_slot);
            edge_wdata <= make_edge('0', (others => '0'), (others => '0'));
            edge_we <= '1';

            if dis_slot = integer(MAX_DEG-1) then
              st <= ret_st;
            else
              dis_slot <= dis_slot + 1;
              st <= ST_DISABLE_CLR;
            end if;

          -- ======================================================
          -- MAY INSERT (lambda)
          -- ======================================================
          when ST_MAY_INSERT =>
            if lambda_cnt = integer(LAMBDA_STEPS-1) then
              lambda_cnt <= 0;
              ins_scan_id <= (others => '0');
              q_err_max <= (others => '0');
              q_id <= (others => '0');
              st <= ST_INS_Q_SET;
            else
              lambda_cnt <= lambda_cnt + 1;
              edec_id <= (others => '0');
              st <= ST_EDEC_SET;
            end if;

          -- ======================================================
          -- INSERT: find q (max error among active)
          -- ======================================================
          when ST_INS_Q_SET =>
            err_raddr <= ins_scan_id;
            st <= ST_INS_Q_WAIT;

          when ST_INS_Q_WAIT =>
            st <= ST_INS_Q_EVAL;

          when ST_INS_Q_EVAL =>
            if is_active(err_rdata) then
              err_u := get_err(err_rdata);
              if err_u > q_err_max then
                q_err_max <= err_u;
                q_id <= ins_scan_id;
              end if;
            end if;

            if ins_scan_id = to_unsigned(MAX_NODES-1, 6) then
              k_slot <= 0;
              f_err_max <= (others => '0');
              f_id <= (others => '0');
              f_slot_q <= 0;
              f_found <= '0';
              st <= ST_INS_F_EDGE_SET;
            else
              ins_scan_id <= ins_scan_id + 1;
              st <= ST_INS_Q_SET;
            end if;

          -- ======================================================
          -- INSERT: scan edges of q to pick f with max error
          -- ======================================================
          when ST_INS_F_EDGE_SET =>
            edge_raddr <= edge_addr(q_id, k_slot);
            st <= ST_INS_F_EDGE_WAIT;

          when ST_INS_F_EDGE_WAIT =>
            st <= ST_INS_F_EDGE_LATCH;

          when ST_INS_F_EDGE_LATCH =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            nb  := edge_nb(ew);

            if vld = '1' then
              nb_id <= nb;
              err_raddr <= nb;
              st <= ST_INS_F_ERR_WAIT;
            else
              if k_slot = integer(MAX_DEG-1) then
                if f_found = '0' then
                  edec_id <= (others => '0');
                  st <= ST_EDEC_SET;
                else
                  ins_scan_id <= (others => '0');
                  free_found <= '0';
                  st <= ST_INS_FREE_SET;
                end if;
              else
                k_slot <= k_slot + 1;
                st <= ST_INS_F_EDGE_SET;
              end if;
            end if;

          when ST_INS_F_ERR_WAIT =>
            st <= ST_INS_F_ERR_LATCH;

          when ST_INS_F_ERR_LATCH =>
            if is_active(err_rdata) then
              err_u := get_err(err_rdata);
              if (f_found = '0') or (err_u > f_err_max) then
                f_found   <= '1';
                f_err_max <= err_u;
                f_id      <= nb_id;
                f_slot_q  <= k_slot;
              end if;
            end if;

            if k_slot = integer(MAX_DEG-1) then
              ins_scan_id <= (others => '0');
              free_found <= '0';
              st <= ST_INS_FREE_SET;
            else
              k_slot <= k_slot + 1;
              st <= ST_INS_F_EDGE_SET;
            end if;

          -- ======================================================
          -- INSERT: find free inactive node r (if none -> stop insert)
          -- ======================================================
          when ST_INS_FREE_SET =>
            err_raddr <= ins_scan_id;
            st <= ST_INS_FREE_WAIT;

          when ST_INS_FREE_WAIT =>
            st <= ST_INS_FREE_EVAL;

          when ST_INS_FREE_EVAL =>
            if (not is_active(err_rdata)) and (free_found = '0') then
              free_found <= '1';
              r_id <= ins_scan_id;
            end if;

            if ins_scan_id = to_unsigned(MAX_NODES-1, 6) then
              if free_found = '0' then
                edec_id <= (others => '0');
                st <= ST_EDEC_SET;
              else
                st <= ST_INS_RDQ_SET;
              end if;
            else
              ins_scan_id <= ins_scan_id + 1;
              st <= ST_INS_FREE_SET;
            end if;

          -- ======================================================
          -- INSERT: read q node
          -- ======================================================
          when ST_INS_RDQ_SET =>
            node_raddr <= q_id;
            st <= ST_INS_RDQ_WAIT;

          when ST_INS_RDQ_WAIT =>
            st <= ST_INS_RDQ_LATCH;

          when ST_INS_RDQ_LATCH =>
            qx_i <= to_integer(signed(node_rdata(15 downto 0)));
            qy_i <= to_integer(signed(node_rdata(31 downto 16)));
            st <= ST_INS_RDF_SET;

          -- ======================================================
          -- INSERT: read f node
          -- ======================================================
          when ST_INS_RDF_SET =>
            node_raddr <= f_id;
            st <= ST_INS_RDF_WAIT;

          when ST_INS_RDF_WAIT =>
            st <= ST_INS_RDF_LATCH;

          when ST_INS_RDF_LATCH =>
            fx_i <= to_integer(signed(node_rdata(15 downto 0)));
            fy_i <= to_integer(signed(node_rdata(31 downto 16)));
            st <= ST_INS_WR_R;

          -- ======================================================
          -- INSERT: write r node + err(r) = reduced(q_err)
          -- ======================================================
          when ST_INS_WR_R =>
            qx := qx_i; qy := qy_i;
            fx := fx_i; fy := fy_i;

            rx := sat16((qx + fx) / 2);
            ry := sat16((qy + fy) / 2);

            if ALPHA_SHIFT = 0 then
              new_q_err := q_err_max;
            else
              new_q_err := shift_right(q_err_max, integer(ALPHA_SHIFT));
            end if;

            node_waddr <= r_id;
            node_wdata <= std_logic_vector(to_signed(ry,16)) & std_logic_vector(to_signed(rx,16));
            node_we <= '1';

            err_waddr <= r_id;
            err_wdata <= pack_err('1', new_q_err);
            err_we <= '1';

            st <= ST_INS_WR_QERR;

          when ST_INS_WR_QERR =>
            old_q_err := q_err_max;
            if ALPHA_SHIFT = 0 then
              new_q_err := old_q_err;
            else
              new_q_err := shift_right(old_q_err, integer(ALPHA_SHIFT));
            end if;

            err_waddr <= q_id;
            err_wdata <= pack_err('1', new_q_err);
            err_we <= '1';

            st <= ST_INS_WR_FERR;

          when ST_INS_WR_FERR =>
            if ALPHA_SHIFT = 0 then
              new_f_err := f_err_max;
            else
              new_f_err := shift_right(f_err_max, integer(ALPHA_SHIFT));
            end if;

            err_waddr <= f_id;
            err_wdata <= pack_err('1', new_f_err);
            err_we <= '1';

            st <= ST_INS_WR_QEDGE;

          when ST_INS_WR_QEDGE =>
            edge_waddr <= edge_addr(q_id, f_slot_q);
            edge_wdata <= make_edge('1', (others => '0'), r_id);
            edge_we <= '1';

            k_slot <= 0;
            fq_found <= '0';
            fq_slot_f <= 0;
            st <= ST_INS_FIND_FQ_SET;

          when ST_INS_FIND_FQ_SET =>
            edge_raddr <= edge_addr(f_id, k_slot);
            st <= ST_INS_FIND_FQ_WAIT;

          when ST_INS_FIND_FQ_WAIT =>
            st <= ST_INS_FIND_FQ_LATCH;

          when ST_INS_FIND_FQ_LATCH =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            nb  := edge_nb(ew);

            found_slot_local := fq_found;

            if (vld = '1') and (nb = q_id) and (found_slot_local = '0') then
              fq_found  <= '1';
              fq_slot_f <= k_slot;
            end if;

            if k_slot = integer(MAX_DEG-1) then
              if fq_found = '0' then
                edec_id <= (others => '0');
                st <= ST_EDEC_SET;
              else
                st <= ST_INS_WR_FEDGE;
              end if;
            else
              k_slot <= k_slot + 1;
              st <= ST_INS_FIND_FQ_SET;
            end if;

          when ST_INS_WR_FEDGE =>
            edge_waddr <= edge_addr(f_id, fq_slot_f);
            edge_wdata <= make_edge('1', (others => '0'), r_id);
            edge_we <= '1';
            st <= ST_INS_WR_REDGE0;

          when ST_INS_WR_REDGE0 =>
            edge_waddr <= edge_addr(r_id, 0);
            edge_wdata <= make_edge('1', (others => '0'), q_id);
            edge_we <= '1';
            st <= ST_INS_WR_REDGE1;

          when ST_INS_WR_REDGE1 =>
            edge_waddr <= edge_addr(r_id, 1);
            edge_wdata <= make_edge('1', (others => '0'), f_id);
            edge_we <= '1';

            edec_id <= (others => '0');
            st <= ST_EDEC_SET;

          -- ======================================================
          -- FRITZKE GLOBAL ERROR DECAY (per step)
          -- ======================================================
          when ST_EDEC_SET =>
            err_raddr <= edec_id;
            st <= ST_EDEC_WAIT;

          when ST_EDEC_WAIT =>
            st <= ST_EDEC_LATCH;

          when ST_EDEC_LATCH =>
            if is_active(err_rdata) then
              err_u := get_err(err_rdata);

              if BETA_SHIFT = 0 then
                dec_tmp := err_u;
              else
                dec_tmp := err_u - shift_right(err_u, integer(BETA_SHIFT));
              end if;

              err_waddr <= edec_id;
              err_wdata <= pack_err('1', dec_tmp);
              err_we <= '1';
            end if;

            if edec_id = to_unsigned(MAX_NODES-1, 6) then
              st <= ST_NEXT;
            else
              edec_id <= edec_id + 1;
              st <= ST_EDEC_SET;
            end if;

          -- ======================================================
          -- NEXT STEP
          -- ======================================================
          when ST_NEXT =>
            if sample_idx = to_unsigned(DATA_WORDS-1, sample_idx'length) then
              sample_idx <= (others => '0');
            else
              sample_idx <= sample_idx + 1;
            end if;

            if steps_left <= 1 then
              st <= ST_DONE;
            else
              steps_left <= steps_left - 1;
              st <= ST_DATA_SET;
            end if;

          when ST_DONE =>
            done_pulse <= '1';
            st <= ST_IDLE;

          when others =>
            st <= ST_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture;