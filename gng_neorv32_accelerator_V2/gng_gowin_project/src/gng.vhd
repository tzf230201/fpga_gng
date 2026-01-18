library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng is
  generic (
    MAX_NODES        : natural := 40;  -- <= 64 (karena neighbor id 6-bit)
    MAX_DEG          : natural := 6;
    A_MAX            : natural := 50;
    DATA_WORDS       : natural := 100; -- jumlah word32 dataset
    DONE_EVERY_STEPS : natural := 10;

    INIT_X0          : integer := 200;
    INIT_Y0          : integer := 200;
    INIT_X1          : integer := 800;
    INIT_Y1          : integer := 800;

    LEARN_SHIFT      : natural := 4;   -- eps_b = 1/16
    NB_LEARN_SHIFT   : natural := 6    -- eps_n = 1/64 (lebih kecil)
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in  std_logic; -- pulse untuk mulai batch step

    -- dataset word32 sync read 1-cycle (dari mem_c top)
    data_raddr_o : out unsigned(6 downto 0); -- 0..127
    data_rdata_i : in  std_logic_vector(31 downto 0);

    gng_done_o : out std_logic; -- 1-cycle pulse tiap DONE_EVERY_STEPS step
    gng_busy_o : out std_logic;

    s1_id_o : out unsigned(5 downto 0);
    s2_id_o : out unsigned(5 downto 0)
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
    if v > 32767 then return 32767;
    elsif v < -32768 then return -32768;
    else return v;
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

  constant EDGE_DEPTH : natural := MAX_NODES * MAX_DEG;
  constant EDGE_AW    : natural := clog2(EDGE_DEPTH); -- e.g. 240 -> 8

  -- ============================================================
  -- BRAM-style memories
  -- ============================================================

  -- node_mem[i] : [31:16]=y(s16), [15:0]=x(s16)
  type node_mem_t is array (0 to MAX_NODES-1) of std_logic_vector(31 downto 0);
  signal node_mem : node_mem_t := (others => (others => '0'));
  signal node_raddr : unsigned(5 downto 0) := (others => '0');
  signal node_rdata : std_logic_vector(31 downto 0) := (others => '0');
  signal node_we    : std_logic := '0';
  signal node_waddr : unsigned(5 downto 0) := (others => '0');
  signal node_wdata : std_logic_vector(31 downto 0) := (others => '0');

  -- err_mem[i] : bit31=active, bits30..0=unsigned error
  type err_mem_t is array (0 to MAX_NODES-1) of std_logic_vector(31 downto 0);
  signal err_mem : err_mem_t := (others => (others => '0'));
  signal err_raddr : unsigned(5 downto 0) := (others => '0');
  signal err_rdata : std_logic_vector(31 downto 0) := (others => '0');
  signal err_we    : std_logic := '0';
  signal err_waddr : unsigned(5 downto 0) := (others => '0');
  signal err_wdata : std_logic_vector(31 downto 0) := (others => '0');

  -- edge_mem[ node*MAX_DEG + slot ] : 16-bit
  -- [15]=valid, [14:7]=age(8), [6:1]=nb_id(6), [0]=0
  type edge_mem_t is array (0 to EDGE_DEPTH-1) of std_logic_vector(15 downto 0);
  signal edge_mem : edge_mem_t := (others => (others => '0'));
  signal edge_raddr : unsigned(EDGE_AW-1 downto 0) := (others => '0');
  signal edge_rdata : std_logic_vector(15 downto 0) := (others => '0');
  signal edge_we    : std_logic := '0';
  signal edge_waddr : unsigned(EDGE_AW-1 downto 0) := (others => '0');
  signal edge_wdata : std_logic_vector(15 downto 0) := (others => '0');

  function edge_valid(w : std_logic_vector(15 downto 0)) return std_logic is
  begin
    return w(15);
  end function;

  function edge_age(w : std_logic_vector(15 downto 0)) return unsigned is
  begin
    return unsigned(w(14 downto 7));
  end function;

  function edge_nb(w : std_logic_vector(15 downto 0)) return unsigned is
  begin
    return unsigned(w(6 downto 1));
  end function;

  function make_edge(vld : std_logic; age : unsigned(7 downto 0); nb : unsigned(5 downto 0)) return std_logic_vector is
    variable r : std_logic_vector(15 downto 0);
  begin
    r(15) := vld;
    r(14 downto 7) := std_logic_vector(age);
    r(6 downto 1) := std_logic_vector(nb);
    r(0) := '0';
    return r;
  end function;

  function is_active(e : std_logic_vector(31 downto 0)) return boolean is
  begin
    return (e(31) = '1');
  end function;

  function get_err(e : std_logic_vector(31 downto 0)) return unsigned is
  begin
    return unsigned(e(30 downto 0));
  end function;

  function pack_err(active : std_logic; val : unsigned(30 downto 0)) return std_logic_vector is
    variable r : std_logic_vector(31 downto 0);
  begin
    r(31) := active;
    r(30 downto 0) := std_logic_vector(val);
    return r;
  end function;

  -- ============================================================
  -- FSM
  -- ============================================================
  type st_t is (
    ST_IDLE,

    ST_INIT_NODES_SET, ST_INIT_NODES_WAIT,
    ST_INIT_EDGES_SET, ST_INIT_EDGES_WAIT,

    ST_SET_DATA, ST_WAIT_DATA, ST_LATCH_DATA,

    ST_FIND_SET, ST_FIND_WAIT, ST_FIND_EVAL,

    ST_AGE_SET, ST_AGE_WAIT, ST_AGE_LATCH,
    ST_RM_SCAN_SET, ST_RM_SCAN_WAIT, ST_RM_SCAN_LATCH,

    ST_CONN_S1_SET, ST_CONN_S1_WAIT, ST_CONN_S1_LATCH,
    ST_CONN_S2_SET, ST_CONN_S2_WAIT, ST_CONN_S2_LATCH,
    ST_CONN_WRITE1, ST_CONN_WRITE2,

    ST_UPD_S1_SET, ST_UPD_S1_WAIT, ST_UPD_S1_LATCH,
    ST_UPD_S1_WR,

    -- NEW: neighbor update
    ST_NB_EDGE_SET, ST_NB_EDGE_WAIT, ST_NB_EDGE_LATCH,
    ST_NB_NODE_SET, ST_NB_NODE_WAIT, ST_NB_NODE_LATCH,
    ST_NB_NODE_WR,

    ST_STEP_NEXT,
    ST_DONE
  );
  signal st : st_t := ST_IDLE;

  -- start pulse
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  -- init sweep counters
  signal init_i      : unsigned(5 downto 0) := (others => '0'); -- node index
  signal init_edge_i : unsigned(EDGE_AW-1 downto 0) := (others => '0');

  signal inited : std_logic := '0';

  -- dataset
  signal sample_idx : unsigned(6 downto 0) := (others => '0');
  signal sx_i, sy_i : integer := 0;

  -- batch step counter
  signal steps_left : integer := 0;

  -- find winners
  signal node_idx : unsigned(5 downto 0) := (others => '0');
  signal best1    : integer := 2147483647;
  signal best2    : integer := 2147483647;
  signal s1_id    : unsigned(5 downto 0) := (others => '0');
  signal s2_id    : unsigned(5 downto 0) := (others => '0');

  -- edge scan/aging/connect
  signal k_slot : integer range 0 to 255 := 0;
  signal rm_k   : integer range 0 to 255 := 0;
  signal rm_nb  : unsigned(5 downto 0) := (others => '0');

  -- connect bookkeeping
  signal c_found1 : std_logic := '0';
  signal c_found2 : std_logic := '0';
  signal c_slot1  : integer range 0 to 255 := 0;
  signal c_slot2  : integer range 0 to 255 := 0;
  signal c_empty1 : integer range 0 to 255 := 0;
  signal c_empty2 : integer range 0 to 255 := 0;

  -- NEW: neighbor update slot counter
  signal nb_slot : integer range 0 to 255 := 0;
  signal nb_id   : unsigned(5 downto 0) := (others => '0');

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
      start_p <= start_i and (not start_d);
      start_d <= start_i;
      if rstn_i = '0' then
        start_d <= '0';
        start_p <= '0';
      end if;
    end if;
  end process;

  -- ============================================================
  -- RAMs: sync write + sync read
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

    variable nword  : std_logic_vector(31 downto 0);
    variable eword  : std_logic_vector(31 downto 0);

    variable ew     : std_logic_vector(15 downto 0);
    variable vld    : std_logic;
    variable age    : unsigned(7 downto 0);
    variable nb     : unsigned(5 downto 0);

    variable base_s1 : integer;
    variable base_s2 : integer;

    variable err_u : unsigned(30 downto 0);
    variable err_n : unsigned(30 downto 0);

    variable upd   : integer;

    constant SLOT_NONE : integer := 255;
  begin
    if rising_edge(clk_i) then
      done_pulse <= '0';

      node_we <= '0';
      err_we  <= '0';
      edge_we <= '0';

      if rstn_i = '0' then
        st <= ST_IDLE;
        inited <= '0';
        init_i <= (others => '0');
        init_edge_i <= (others => '0');

        sample_idx <= (others => '0');
        sx_i <= 0; sy_i <= 0;

        steps_left <= 0;

        node_idx <= (others => '0');
        best1 <= 2147483647;
        best2 <= 2147483647;
        s1_id <= (others => '0');
        s2_id <= (others => '0');

        k_slot <= 0; rm_k <= 0;
        rm_nb <= (others => '0');

        nb_slot <= 0;
        nb_id <= (others => '0');

      else
        case st is

          when ST_IDLE =>
            if start_p = '1' then
              steps_left <= integer(DONE_EVERY_STEPS);

              if inited = '0' then
                init_i <= (others => '0');
                st <= ST_INIT_NODES_SET;
              else
                st <= ST_SET_DATA;
              end if;
            end if;

          -- ======================================================
          -- INIT (multi-cycle, BRAM style)
          -- ======================================================
          when ST_INIT_NODES_SET =>
            -- write node_mem & err_mem for node init_i
            node_waddr <= init_i;
            err_waddr  <= init_i;

            if init_i = to_unsigned(0, 6) then
              node_wdata <= std_logic_vector(to_signed(INIT_Y0,16)) & std_logic_vector(to_signed(INIT_X0,16));
              err_wdata  <= pack_err('1', (others => '0'));
            elsif init_i = to_unsigned(1, 6) then
              node_wdata <= std_logic_vector(to_signed(INIT_Y1,16)) & std_logic_vector(to_signed(INIT_X1,16));
              err_wdata  <= pack_err('1', (others => '0'));
            else
              node_wdata <= (others => '0');
              err_wdata  <= pack_err('0', (others => '0'));
            end if;

            node_we <= '1';
            err_we  <= '1';
            st <= ST_INIT_NODES_WAIT;

          when ST_INIT_NODES_WAIT =>
            if init_i = to_unsigned(MAX_NODES-1, 6) then
              init_edge_i <= (others => '0');
              st <= ST_INIT_EDGES_SET;
            else
              init_i <= init_i + 1;
              st <= ST_INIT_NODES_SET;
            end if;

          when ST_INIT_EDGES_SET =>
            edge_waddr <= init_edge_i;
            edge_wdata <= make_edge('0', (others => '0'), (others => '0'));
            edge_we <= '1';
            st <= ST_INIT_EDGES_WAIT;

          when ST_INIT_EDGES_WAIT =>
            if init_edge_i = to_unsigned(EDGE_DEPTH-1, EDGE_AW) then
              inited <= '1';
              sample_idx <= (others => '0');
              st <= ST_SET_DATA;
            else
              init_edge_i <= init_edge_i + 1;
              st <= ST_INIT_EDGES_SET;
            end if;

          -- ======================================================
          -- READ dataset word32 (sync 1-cycle from top)
          -- ======================================================
          when ST_SET_DATA =>
            st <= ST_WAIT_DATA;

          when ST_WAIT_DATA =>
            st <= ST_LATCH_DATA;

          when ST_LATCH_DATA =>
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
          -- FIND WINNERS (scan 1 node per 3 cycles)
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
              dist := abs_i(dx) + abs_i(dy); -- L1 (hemat LUT)

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
          -- EDGE AGING for edges from s1
          -- ======================================================
          when ST_AGE_SET =>
            base_s1 := to_integer(s1_id) * integer(MAX_DEG);
            edge_raddr <= to_unsigned(base_s1 + k_slot, EDGE_AW);
            st <= ST_AGE_WAIT;

          when ST_AGE_WAIT =>
            st <= ST_AGE_LATCH;

          when ST_AGE_LATCH =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            age := edge_age(ew);
            nb  := edge_nb(ew);

            if vld = '1' then
              -- age++
              if age /= to_unsigned(255, 8) then
                age := age + 1;
              end if;

              if to_integer(age) > integer(A_MAX) then
                -- remove from s1
                base_s1 := to_integer(s1_id) * integer(MAX_DEG);
                edge_waddr <= to_unsigned(base_s1 + k_slot, EDGE_AW);
                edge_wdata <= make_edge('0', (others => '0'), (others => '0'));
                edge_we <= '1';

                -- remove reciprocal in neighbor nb
                rm_nb <= nb;
                rm_k  <= 0;
                st <= ST_RM_SCAN_SET;
              else
                -- write back aged
                base_s1 := to_integer(s1_id) * integer(MAX_DEG);
                edge_waddr <= to_unsigned(base_s1 + k_slot, EDGE_AW);
                edge_wdata <= make_edge('1', age, nb);
                edge_we <= '1';

                if k_slot = integer(MAX_DEG-1) then
                  -- go connect
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

          -- remove reciprocal: scan neighbor slots (rm_nb)
          when ST_RM_SCAN_SET =>
            base_s2 := to_integer(rm_nb) * integer(MAX_DEG);
            edge_raddr <= to_unsigned(base_s2 + rm_k, EDGE_AW);
            st <= ST_RM_SCAN_WAIT;

          when ST_RM_SCAN_WAIT =>
            st <= ST_RM_SCAN_LATCH;

          when ST_RM_SCAN_LATCH =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            nb  := edge_nb(ew);

            if vld = '1' and nb = s1_id then
              base_s2 := to_integer(rm_nb) * integer(MAX_DEG);
              edge_waddr <= to_unsigned(base_s2 + rm_k, EDGE_AW);
              edge_wdata <= make_edge('0', (others => '0'), (others => '0'));
              edge_we <= '1';
            end if;

            if rm_k = integer(MAX_DEG-1) then
              -- resume aging next slot
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
            else
              rm_k <= rm_k + 1;
              st <= ST_RM_SCAN_SET;
            end if;

          -- ======================================================
          -- CONNECT s1-s2 (scan BRAM-style)
          -- ======================================================
          when ST_CONN_S1_SET =>
            base_s1 := to_integer(s1_id) * integer(MAX_DEG);
            edge_raddr <= to_unsigned(base_s1 + k_slot, EDGE_AW);
            st <= ST_CONN_S1_WAIT;

          when ST_CONN_S1_WAIT =>
            st <= ST_CONN_S1_LATCH;

          when ST_CONN_S1_LATCH =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            nb  := edge_nb(ew);

            if vld = '1' and nb = s2_id then
              c_found1 <= '1';
              c_slot1  <= k_slot;
            elsif vld = '0' and c_empty1 = SLOT_NONE then
              c_empty1 <= k_slot;
            end if;

            if k_slot = integer(MAX_DEG-1) then
              k_slot <= 0;
              st <= ST_CONN_S2_SET;
            else
              k_slot <= k_slot + 1;
              st <= ST_CONN_S1_SET;
            end if;

          when ST_CONN_S2_SET =>
            base_s2 := to_integer(s2_id) * integer(MAX_DEG);
            edge_raddr <= to_unsigned(base_s2 + k_slot, EDGE_AW);
            st <= ST_CONN_S2_WAIT;

          when ST_CONN_S2_WAIT =>
            st <= ST_CONN_S2_LATCH;

          when ST_CONN_S2_LATCH =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            nb  := edge_nb(ew);

            if vld = '1' and nb = s1_id then
              c_found2 <= '1';
              c_slot2  <= k_slot;
            elsif vld = '0' and c_empty2 = SLOT_NONE then
              c_empty2 <= k_slot;
            end if;

            if k_slot = integer(MAX_DEG-1) then
              st <= ST_CONN_WRITE1;
            else
              k_slot <= k_slot + 1;
              st <= ST_CONN_S2_SET;
            end if;

          -- write/reset age in two cycles (two entries)
          when ST_CONN_WRITE1 =>
            base_s1 := to_integer(s1_id) * integer(MAX_DEG);
            base_s2 := to_integer(s2_id) * integer(MAX_DEG);

            if c_found1 = '1' then
              edge_waddr <= to_unsigned(base_s1 + c_slot1, EDGE_AW);
              edge_wdata <= make_edge('1', (others => '0'), s2_id);
              edge_we <= '1';
            elsif (c_empty1 /= SLOT_NONE) and (c_empty2 /= SLOT_NONE) then
              edge_waddr <= to_unsigned(base_s1 + c_empty1, EDGE_AW);
              edge_wdata <= make_edge('1', (others => '0'), s2_id);
              edge_we <= '1';
            else
              null;
            end if;

            st <= ST_CONN_WRITE2;

          when ST_CONN_WRITE2 =>
            base_s1 := to_integer(s1_id) * integer(MAX_DEG);
            base_s2 := to_integer(s2_id) * integer(MAX_DEG);

            if c_found2 = '1' then
              edge_waddr <= to_unsigned(base_s2 + c_slot2, EDGE_AW);
              edge_wdata <= make_edge('1', (others => '0'), s1_id);
              edge_we <= '1';
            elsif (c_empty1 /= SLOT_NONE) and (c_empty2 /= SLOT_NONE) then
              edge_waddr <= to_unsigned(base_s2 + c_empty2, EDGE_AW);
              edge_wdata <= make_edge('1', (others => '0'), s1_id);
              edge_we <= '1';
            else
              null;
            end if;

            -- proceed update s1
            st <= ST_UPD_S1_SET;

          -- ======================================================
          -- UPDATE s1 node + error
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

            -- error += best1 (L1)
            err_u := get_err(err_rdata);
            if (err_u + to_unsigned(best1, 31)) > to_unsigned(2**31-1, 31) then
              err_n := (others => '1');
            else
              err_n := err_u + to_unsigned(best1, 31);
            end if;

            err_waddr <= s1_id;
            err_wdata <= pack_err('1', err_n);
            err_we <= '1';

            -- NEW: neighbor update start
            nb_slot <= 0;
            st <= ST_NB_EDGE_SET;

          when ST_UPD_S1_WR =>
            st <= ST_NB_EDGE_SET;

          -- ======================================================
          -- NEW: UPDATE NEIGHBORS of s1
          -- Scan slot 0..MAX_DEG-1:
          -- if valid -> read neighbor node -> update toward (sx,sy) using NB_LEARN_SHIFT
          -- ======================================================
          when ST_NB_EDGE_SET =>
            if nb_slot >= integer(MAX_DEG) then
              st <= ST_STEP_NEXT;
            else
              base_s1 := to_integer(s1_id) * integer(MAX_DEG);
              edge_raddr <= to_unsigned(base_s1 + nb_slot, EDGE_AW);
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
              node_raddr <= nb;  -- read neighbor node
              st <= ST_NB_NODE_WAIT;
            else
              nb_slot <= nb_slot + 1;
              st <= ST_NB_EDGE_SET;
            end if;

          when ST_NB_NODE_WAIT =>
            st <= ST_NB_NODE_LATCH;

          when ST_NB_NODE_LATCH =>
            -- update neighbor node position
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
          -- NEXT STEP
          -- ======================================================
          when ST_STEP_NEXT =>
            if sample_idx = to_unsigned(DATA_WORDS-1, sample_idx'length) then
              sample_idx <= (others => '0');
            else
              sample_idx <= sample_idx + 1;
            end if;

            if steps_left <= 1 then
              st <= ST_DONE;
            else
              steps_left <= steps_left - 1;
              st <= ST_SET_DATA;
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
