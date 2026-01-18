library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng is
  generic (
    MAX_NODES        : natural := 40;
    MAX_DEG          : natural := 6;
    A_MAX            : natural := 50;
    DATA_WORDS       : natural := 100; -- dataset words (word32)
    DONE_EVERY_STEPS : natural := 10;
    LEARN_SHIFT      : natural := 4;   -- 1/16
    INIT_X0          : integer := 200;
    INIT_Y0          : integer := 200;
    INIT_X1          : integer := 800;
    INIT_Y1          : integer := 800
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in  std_logic; -- 1-cycle pulse

    -- dataset word32 (top memberikan sync read)
    data_raddr_o : out unsigned(6 downto 0);
    data_rdata_i : in  std_logic_vector(31 downto 0);

    gng_done_o : out std_logic; -- 1-cycle pulse (tiap DONE_EVERY_STEPS)
    gng_busy_o : out std_logic;

    s1_id_o : out unsigned(5 downto 0);
    s2_id_o : out unsigned(5 downto 0)
  );
end entity;

architecture rtl of gng is

  -- ---------------------------------------------
  -- clog2
  -- ---------------------------------------------
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

  constant NODE_AW     : natural := clog2(MAX_NODES);
  constant EDGE_DEPTH  : natural := MAX_NODES * MAX_DEG;
  constant EDGE_AW     : natural := clog2(EDGE_DEPTH);

  -- ---------------------------------------------
  -- Subtypes (penting untuk tool yang ketat)
  -- ---------------------------------------------
  subtype slv32 is std_logic_vector(31 downto 0);
  subtype slv16 is std_logic_vector(15 downto 0);
  subtype s16   is signed(15 downto 0);
  subtype u6    is unsigned(5 downto 0);
  subtype u7    is unsigned(6 downto 0);
  subtype u8    is unsigned(7 downto 0);
  subtype u16   is unsigned(15 downto 0);
  subtype u17   is unsigned(16 downto 0);
  subtype u31   is unsigned(30 downto 0);

  -- ---------------------------------------------
  -- RAMs (BRAM-style)
  -- node_ram: {y[31:16], x[15:0]}
  -- err_ram : {active[31], err[30:0]}
  -- edge_ram: {0, valid[14], age[13:6], nbid[5:0]}
  -- ---------------------------------------------
  type node_ram_t is array (0 to MAX_NODES-1) of slv32;
  type err_ram_t  is array (0 to MAX_NODES-1) of slv32;
  type edge_ram_t is array (0 to EDGE_DEPTH-1) of slv16;

  signal node_ram : node_ram_t;
  signal err_ram  : err_ram_t;
  signal edge_ram : edge_ram_t;

  -- node ports
  signal node_raddr : unsigned(NODE_AW-1 downto 0) := (others => '0');
  signal node_rdata : slv32 := (others => '0');
  signal node_we    : std_logic := '0';
  signal node_waddr : unsigned(NODE_AW-1 downto 0) := (others => '0');
  signal node_wdata : slv32 := (others => '0');

  -- err ports
  signal err_raddr  : unsigned(NODE_AW-1 downto 0) := (others => '0');
  signal err_rdata  : slv32 := (others => '0');
  signal err_we     : std_logic := '0';
  signal err_waddr  : unsigned(NODE_AW-1 downto 0) := (others => '0');
  signal err_wdata  : slv32 := (others => '0');

  -- edge ports
  signal edge_raddr : unsigned(EDGE_AW-1 downto 0) := (others => '0');
  signal edge_rdata : slv16 := (others => '0');
  signal edge_we    : std_logic := '0';
  signal edge_waddr : unsigned(EDGE_AW-1 downto 0) := (others => '0');
  signal edge_wdata : slv16 := (others => '0');

  -- degree regs (small)
  type deg_arr_t is array (0 to MAX_NODES-1) of unsigned(3 downto 0);
  signal deg : deg_arr_t := (others => (others => '0'));

  -- ---------------------------------------------
  -- Helper functions
  -- ---------------------------------------------
  function sat16_i(v : integer) return integer is
  begin
    if v > 32767 then return 32767;
    elsif v < -32768 then return -32768;
    else return v;
    end if;
  end function;

  function abs_s16(a : s16) return u16 is
    variable v : s16 := a;
  begin
    if v(15)='1' then
      return unsigned(-v);
    else
      return unsigned(v);
    end if;
  end function;

  function pack_node(xv, yv : s16) return slv32 is
    variable r : slv32;
  begin
    r(15 downto 0)  := std_logic_vector(xv);
    r(31 downto 16) := std_logic_vector(yv);
    return r;
  end function;

  function get_x(nw : slv32) return s16 is
  begin
    return signed(nw(15 downto 0));
  end function;

  function get_y(nw : slv32) return s16 is
  begin
    return signed(nw(31 downto 16));
  end function;

  function pack_err(active : std_logic; v : u31) return slv32 is
    variable r : slv32;
  begin
    r(31) := active;
    r(30 downto 0) := std_logic_vector(v);
    return r;
  end function;

  function is_active(e : slv32) return boolean is
  begin
    return (e(31)='1');
  end function;

  function get_err(e : slv32) return u31 is
  begin
    return unsigned(e(30 downto 0));
  end function;

  function edge_pack(valid : std_logic; age : u8; nbid : u6) return slv16 is
    variable r : slv16;
  begin
    r(15) := '0';
    r(14) := valid;
    r(13 downto 6) := std_logic_vector(age);
    r(5 downto 0)  := std_logic_vector(nbid);
    return r;
  end function;

  function edge_valid(w : slv16) return std_logic is
  begin
    return w(14);
  end function;

  function edge_age(w : slv16) return u8 is
  begin
    return unsigned(w(13 downto 6));
  end function;

  function edge_nbid(w : slv16) return u6 is
  begin
    return unsigned(w(5 downto 0));
  end function;

  -- ---------------------------------------------
  -- FSM
  -- ---------------------------------------------
  type st_t is (
    ST_IDLE,

    -- init clear
    ST_INIT_EDGE_SET, ST_INIT_EDGE_NEXT,
    ST_INIT_NODE_SET, ST_INIT_NODE_NEXT,
    ST_INIT_SET_N0,
    ST_INIT_SET_N1,
    ST_READY,

    -- read sample
    ST_SAMP_SET, ST_SAMP_WAIT, ST_SAMP_LATCH,

    -- find winner scan (1 node per 3 cycles)
    ST_FIND_INIT,
    ST_FIND_SET, ST_FIND_WAIT, ST_FIND_EVAL,
    ST_FIND_NEXT,

    -- edge aging on s1
    ST_AGE_INIT,
    ST_AGE_SET, ST_AGE_WAIT, ST_AGE_EVAL,
    ST_RM_INIT, ST_RM_SET, ST_RM_WAIT, ST_RM_EVAL,
    ST_AGE_NEXT,

    -- connect s1-s2
    ST_CONN_INIT_S1,
    ST_CONN_S1_SET, ST_CONN_S1_WAIT, ST_CONN_S1_EVAL, ST_CONN_S1_NEXT,
    ST_CONN_INIT_S2,
    ST_CONN_S2_SET, ST_CONN_S2_WAIT, ST_CONN_S2_EVAL, ST_CONN_S2_NEXT,
    ST_CONN_DECIDE,
    ST_CONN_WR1, ST_CONN_WR2,

    -- update node + error
    ST_UPD_SET, ST_UPD_WAIT, ST_UPD_EVAL,

    -- step
    ST_STEP_NEXT,
    ST_DONE
  );

  signal st : st_t := ST_IDLE;

  -- start edge detect
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  -- init counters
  signal init_edge_idx : unsigned(EDGE_AW-1 downto 0) := (others => '0');
  signal init_node_idx : unsigned(NODE_AW-1 downto 0) := (others => '0');
  signal inited        : std_logic := '0';

  -- dataset index
  signal sample_idx : u7 := (others => '0');
  signal sx, sy     : s16 := (others => '0');

  -- batch steps
  signal steps_left : integer := 0;

  -- find scan
  signal scan_idx : unsigned(NODE_AW-1 downto 0) := (others => '0');
  signal best1    : u17 := (others => '1');
  signal best2    : u17 := (others => '1');
  signal s1_id    : u6  := (others => '0');
  signal s2_id    : u6  := (others => '0');

  -- aging scan
  signal age_slot      : integer range 0 to 255 := 0;
  signal rm_slot       : integer range 0 to 255 := 0;
  signal rm_nbid_reg   : u6 := (others => '0');
  signal age_resume    : integer range 0 to 255 := 0;

  -- connect scan flags
  signal conn_slot   : integer range 0 to 255 := 0;
  signal s1_found    : std_logic := '0';
  signal s2_found    : std_logic := '0';
  signal s1_emp      : std_logic := '0';
  signal s2_emp      : std_logic := '0';
  signal s1_slot_f   : integer range 0 to 255 := 0;
  signal s2_slot_f   : integer range 0 to 255 := 0;
  signal s1_slot_e   : integer range 0 to 255 := 0;
  signal s2_slot_e   : integer range 0 to 255 := 0;

  signal wr1_do     : std_logic := '0';
  signal wr2_do     : std_logic := '0';
  signal wr1_addr   : unsigned(EDGE_AW-1 downto 0) := (others => '0');
  signal wr2_addr   : unsigned(EDGE_AW-1 downto 0) := (others => '0');
  signal wr1_data   : slv16 := (others => '0');
  signal wr2_data   : slv16 := (others => '0');

  signal done_p : std_logic := '0';

begin

  data_raddr_o <= sample_idx;

  gng_done_o <= done_p;
  gng_busy_o <= '0' when (st = ST_IDLE or st = ST_READY) else '1';

  s1_id_o <= s1_id;
  s2_id_o <= s2_id;

  -- ---------------------------------------------
  -- RAM sync read/write
  -- ---------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if node_we='1' then
        node_ram(to_integer(node_waddr)) <= node_wdata;
      end if;
      node_rdata <= node_ram(to_integer(node_raddr));
    end if;
  end process;

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if err_we='1' then
        err_ram(to_integer(err_waddr)) <= err_wdata;
      end if;
      err_rdata <= err_ram(to_integer(err_raddr));
    end if;
  end process;

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if edge_we='1' then
        edge_ram(to_integer(edge_waddr)) <= edge_wdata;
      end if;
      edge_rdata <= edge_ram(to_integer(edge_raddr));
    end if;
  end process;

  -- start pulse detect
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      start_p <= start_i and (not start_d);
      start_d <= start_i;
      if rstn_i='0' then
        start_d <= '0';
        start_p <= '0';
      end if;
    end if;
  end process;

  -- ---------------------------------------------
  -- Main FSM
  -- ---------------------------------------------
  process(clk_i)
    variable nw : slv32;
    variable ew : slv16;
    variable ex : slv32;

    variable xw, yw : s16;
    variable dx, dy : s16;
    variable dist   : u17;

    variable age  : u8;
    variable nbid : u6;
    variable vld  : std_logic;
    variable age_next : u8;

    variable base_i : integer;
    variable errv   : u31;

    variable xnew_i, ynew_i : integer;
    variable xnew, ynew : s16;

    variable ok_sym : boolean;
    variable s1_base_u, s2_base_u : unsigned(EDGE_AW-1 downto 0);
  begin
    if rising_edge(clk_i) then

      -- defaults
      done_p  <= '0';
      node_we <= '0';
      err_we  <= '0';
      edge_we <= '0';

      if rstn_i='0' then
        st <= ST_IDLE;
        inited <= '0';
        init_edge_idx <= (others => '0');
        init_node_idx <= (others => '0');
        sample_idx <= (others => '0');
        steps_left <= 0;

        scan_idx <= (others => '0');
        best1 <= (others => '1');
        best2 <= (others => '1');
        s1_id <= (others => '0');
        s2_id <= (others => '0');

        age_slot <= 0;
        rm_slot <= 0;
        rm_nbid_reg <= (others => '0');
        age_resume <= 0;

        conn_slot <= 0;
        s1_found <= '0'; s2_found <= '0';
        s1_emp <= '0';   s2_emp <= '0';

        deg <= (others => (others => '0'));

      else

        case st is

          -- =========================
          -- IDLE / START
          -- =========================
          when ST_IDLE =>
            if start_p='1' then
              steps_left <= integer(DONE_EVERY_STEPS);

              if inited='0' then
                init_edge_idx <= (others => '0');
                st <= ST_INIT_EDGE_SET;
              else
                st <= ST_READY;
              end if;
            end if;

          when ST_READY =>
            -- masuk batch training
            st <= ST_SAMP_SET;

          -- =========================
          -- INIT: clear edge RAM
          -- =========================
          when ST_INIT_EDGE_SET =>
            edge_waddr <= init_edge_idx;
            edge_wdata <= (others => '0');
            edge_we    <= '1';
            st <= ST_INIT_EDGE_NEXT;

          when ST_INIT_EDGE_NEXT =>
            if init_edge_idx = to_unsigned(EDGE_DEPTH-1, EDGE_AW) then
              init_node_idx <= (others => '0');
              st <= ST_INIT_NODE_SET;
            else
              init_edge_idx <= init_edge_idx + 1;
              st <= ST_INIT_EDGE_SET;
            end if;

          -- clear node + error + deg
          when ST_INIT_NODE_SET =>
            node_waddr <= init_node_idx;
            node_wdata <= (others => '0');
            node_we    <= '1';

            err_waddr  <= init_node_idx;
            err_wdata  <= pack_err('0', (others => '0'));
            err_we     <= '1';

            deg(to_integer(init_node_idx)) <= (others => '0');

            st <= ST_INIT_NODE_NEXT;

          when ST_INIT_NODE_NEXT =>
            if init_node_idx = to_unsigned(MAX_NODES-1, NODE_AW) then
              st <= ST_INIT_SET_N0;
            else
              init_node_idx <= init_node_idx + 1;
              st <= ST_INIT_NODE_SET;
            end if;

          when ST_INIT_SET_N0 =>
            node_waddr <= to_unsigned(0, NODE_AW);
            node_wdata <= pack_node(to_signed(sat16_i(INIT_X0),16), to_signed(sat16_i(INIT_Y0),16));
            node_we    <= '1';

            err_waddr  <= to_unsigned(0, NODE_AW);
            err_wdata  <= pack_err('1', (others => '0'));
            err_we     <= '1';

            st <= ST_INIT_SET_N1;

          when ST_INIT_SET_N1 =>
            node_waddr <= to_unsigned(1, NODE_AW);
            node_wdata <= pack_node(to_signed(sat16_i(INIT_X1),16), to_signed(sat16_i(INIT_Y1),16));
            node_we    <= '1';

            err_waddr  <= to_unsigned(1, NODE_AW);
            err_wdata  <= pack_err('1', (others => '0'));
            err_we     <= '1';

            inited <= '1';
            st <= ST_READY;

          -- =========================
          -- SAMPLE read (sync 1-cycle)
          -- =========================
          when ST_SAMP_SET =>
            st <= ST_SAMP_WAIT;

          when ST_SAMP_WAIT =>
            st <= ST_SAMP_LATCH;

          when ST_SAMP_LATCH =>
            sx <= signed(data_rdata_i(15 downto 0));
            sy <= signed(data_rdata_i(31 downto 16));
            st <= ST_FIND_INIT;

          -- =========================
          -- FIND WINNERS (L1 distance)
          -- =========================
          when ST_FIND_INIT =>
            scan_idx <= (others => '0');
            best1 <= (others => '1');
            best2 <= (others => '1');
            s1_id <= (others => '0');
            s2_id <= (others => '0');
            st <= ST_FIND_SET;

          when ST_FIND_SET =>
            node_raddr <= scan_idx;
            err_raddr  <= scan_idx;
            st <= ST_FIND_WAIT;

          when ST_FIND_WAIT =>
            st <= ST_FIND_EVAL;

          when ST_FIND_EVAL =>
            nw := node_rdata;
            ex := err_rdata;

            if is_active(ex) then
              xw := get_x(nw);
              yw := get_y(nw);

              dx := sx - xw;
              dy := sy - yw;

              dist := resize(abs_s16(dx), 17) + resize(abs_s16(dy), 17);

              if dist < best1 then
                best2 <= best1;
                s2_id <= s1_id;
                best1 <= dist;
                s1_id <= resize(scan_idx, 6);
              elsif dist < best2 then
                if resize(scan_idx,6) /= s1_id then
                  best2 <= dist;
                  s2_id <= resize(scan_idx,6);
                end if;
              end if;
            end if;

            st <= ST_FIND_NEXT;

          when ST_FIND_NEXT =>
            if scan_idx = to_unsigned(MAX_NODES-1, NODE_AW) then
              age_slot <= 0;
              st <= ST_AGE_INIT;
            else
              scan_idx <= scan_idx + 1;
              st <= ST_FIND_SET;
            end if;

          -- =========================
          -- EDGE AGING (slot per cycle)
          -- =========================
          when ST_AGE_INIT =>
            age_slot <= 0;
            st <= ST_AGE_SET;

          when ST_AGE_SET =>
            base_i := to_integer(s1_id) * integer(MAX_DEG) + age_slot;
            edge_raddr <= to_unsigned(base_i, EDGE_AW);
            st <= ST_AGE_WAIT;

          when ST_AGE_WAIT =>
            st <= ST_AGE_EVAL;

          when ST_AGE_EVAL =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            age := edge_age(ew);
            nbid := edge_nbid(ew);

            if vld='1' then
              if age = to_unsigned(255,8) then
                age_next := age;
              else
                age_next := age + 1;
              end if;

              if to_integer(age_next) > integer(A_MAX) then
                -- prune slot di s1
                base_i := to_integer(s1_id) * integer(MAX_DEG) + age_slot;
                edge_waddr <= to_unsigned(base_i, EDGE_AW);
                edge_wdata <= (others => '0');
                edge_we    <= '1';

                if deg(to_integer(s1_id)) > 0 then
                  deg(to_integer(s1_id)) <= deg(to_integer(s1_id)) - 1;
                end if;

                rm_nbid_reg <= nbid;
                rm_slot <= 0;
                age_resume <= age_slot; -- lanjut aging setelah reciprocal remove
                st <= ST_RM_INIT;

              else
                -- write back age+1
                base_i := to_integer(s1_id) * integer(MAX_DEG) + age_slot;
                edge_waddr <= to_unsigned(base_i, EDGE_AW);
                edge_wdata <= edge_pack('1', age_next, nbid);
                edge_we    <= '1';
                st <= ST_AGE_NEXT;
              end if;

            else
              st <= ST_AGE_NEXT;
            end if;

          -- remove reciprocal (scan node rm_nbid_reg)
          when ST_RM_INIT =>
            rm_slot <= 0;
            st <= ST_RM_SET;

          when ST_RM_SET =>
            base_i := to_integer(rm_nbid_reg) * integer(MAX_DEG) + rm_slot;
            edge_raddr <= to_unsigned(base_i, EDGE_AW);
            st <= ST_RM_WAIT;

          when ST_RM_WAIT =>
            st <= ST_RM_EVAL;

          when ST_RM_EVAL =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            nbid := edge_nbid(ew);

            if (vld='1') and (nbid = s1_id) then
              base_i := to_integer(rm_nbid_reg) * integer(MAX_DEG) + rm_slot;
              edge_waddr <= to_unsigned(base_i, EDGE_AW);
              edge_wdata <= (others => '0');
              edge_we    <= '1';

              if deg(to_integer(rm_nbid_reg)) > 0 then
                deg(to_integer(rm_nbid_reg)) <= deg(to_integer(rm_nbid_reg)) - 1;
              end if;
            end if;

            if rm_slot = integer(MAX_DEG)-1 then
              -- balik lanjut aging slot berikutnya
              age_slot <= age_resume + 1;
              st <= ST_AGE_NEXT;
            else
              rm_slot <= rm_slot + 1;
              st <= ST_RM_SET;
            end if;

          when ST_AGE_NEXT =>
            if age_slot >= integer(MAX_DEG)-1 then
              st <= ST_CONN_INIT_S1;
            else
              age_slot <= age_slot + 1;
              st <= ST_AGE_SET;
            end if;

          -- =========================
          -- CONNECT s1-s2 (scan s1 list)
          -- =========================
          when ST_CONN_INIT_S1 =>
            conn_slot <= 0;
            s1_found <= '0';
            s1_emp   <= '0';
            st <= ST_CONN_S1_SET;

          when ST_CONN_S1_SET =>
            base_i := to_integer(s1_id) * integer(MAX_DEG) + conn_slot;
            edge_raddr <= to_unsigned(base_i, EDGE_AW);
            st <= ST_CONN_S1_WAIT;

          when ST_CONN_S1_WAIT =>
            st <= ST_CONN_S1_EVAL;

          when ST_CONN_S1_EVAL =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            nbid := edge_nbid(ew);

            if vld='1' then
              if nbid = s2_id then
                s1_found <= '1';
                s1_slot_f <= conn_slot;
              end if;
            else
              if s1_emp='0' then
                s1_emp <= '1';
                s1_slot_e <= conn_slot;
              end if;
            end if;

            st <= ST_CONN_S1_NEXT;

          when ST_CONN_S1_NEXT =>
            if conn_slot = integer(MAX_DEG)-1 then
              st <= ST_CONN_INIT_S2;
            else
              conn_slot <= conn_slot + 1;
              st <= ST_CONN_S1_SET;
            end if;

          -- scan s2 list
          when ST_CONN_INIT_S2 =>
            conn_slot <= 0;
            s2_found <= '0';
            s2_emp   <= '0';
            st <= ST_CONN_S2_SET;

          when ST_CONN_S2_SET =>
            base_i := to_integer(s2_id) * integer(MAX_DEG) + conn_slot;
            edge_raddr <= to_unsigned(base_i, EDGE_AW);
            st <= ST_CONN_S2_WAIT;

          when ST_CONN_S2_WAIT =>
            st <= ST_CONN_S2_EVAL;

          when ST_CONN_S2_EVAL =>
            ew  := edge_rdata;
            vld := edge_valid(ew);
            nbid := edge_nbid(ew);

            if vld='1' then
              if nbid = s1_id then
                s2_found <= '1';
                s2_slot_f <= conn_slot;
              end if;
            else
              if s2_emp='0' then
                s2_emp <= '1';
                s2_slot_e <= conn_slot;
              end if;
            end if;

            st <= ST_CONN_S2_NEXT;

          when ST_CONN_S2_NEXT =>
            if conn_slot = integer(MAX_DEG)-1 then
              st <= ST_CONN_DECIDE;
            else
              conn_slot <= conn_slot + 1;
              st <= ST_CONN_S2_SET;
            end if;

          -- decide and plan 2 writes
          when ST_CONN_DECIDE =>
            wr1_do <= '0';
            wr2_do <= '0';

            s1_base_u := to_unsigned(to_integer(s1_id) * integer(MAX_DEG), EDGE_AW);
            s2_base_u := to_unsigned(to_integer(s2_id) * integer(MAX_DEG), EDGE_AW);

            -- require symmetry (keduanya harus bisa write)
            ok_sym := true;
            if (s1_found='0' and s1_emp='0') then ok_sym := false; end if;
            if (s2_found='0' and s2_emp='0') then ok_sym := false; end if;

            if ok_sym then
              -- s1 side
              if s1_found='1' then
                wr1_addr <= s1_base_u + to_unsigned(s1_slot_f, EDGE_AW);
                wr1_data <= edge_pack('1', (others=>'0'), s2_id);
                wr1_do   <= '1';
              else
                wr1_addr <= s1_base_u + to_unsigned(s1_slot_e, EDGE_AW);
                wr1_data <= edge_pack('1', (others=>'0'), s2_id);
                wr1_do   <= '1';
                if deg(to_integer(s1_id)) < to_unsigned(MAX_DEG,4) then
                  deg(to_integer(s1_id)) <= deg(to_integer(s1_id)) + 1;
                end if;
              end if;

              -- s2 side
              if s2_found='1' then
                wr2_addr <= s2_base_u + to_unsigned(s2_slot_f, EDGE_AW);
                wr2_data <= edge_pack('1', (others=>'0'), s1_id);
                wr2_do   <= '1';
              else
                wr2_addr <= s2_base_u + to_unsigned(s2_slot_e, EDGE_AW);
                wr2_data <= edge_pack('1', (others=>'0'), s1_id);
                wr2_do   <= '1';
                if deg(to_integer(s2_id)) < to_unsigned(MAX_DEG,4) then
                  deg(to_integer(s2_id)) <= deg(to_integer(s2_id)) + 1;
                end if;
              end if;
            end if;

            st <= ST_CONN_WR1;

          when ST_CONN_WR1 =>
            if wr1_do='1' then
              edge_waddr <= wr1_addr;
              edge_wdata <= wr1_data;
              edge_we    <= '1';
            end if;
            st <= ST_CONN_WR2;

          when ST_CONN_WR2 =>
            if wr2_do='1' then
              edge_waddr <= wr2_addr;
              edge_wdata <= wr2_data;
              edge_we    <= '1';
            end if;
            st <= ST_UPD_SET;

          -- =========================
          -- UPDATE winner (node + error)
          -- =========================
          when ST_UPD_SET =>
            node_raddr <= resize(s1_id, NODE_AW);
            err_raddr  <= resize(s1_id, NODE_AW);
            st <= ST_UPD_WAIT;

          when ST_UPD_WAIT =>
            st <= ST_UPD_EVAL;

          when ST_UPD_EVAL =>
            nw := node_rdata;
            ex := err_rdata;

            xw := get_x(nw);
            yw := get_y(nw);

            dx := sx - xw;
            dy := sy - yw;

            xnew_i := to_integer(xw) + to_integer(shift_right(dx, integer(LEARN_SHIFT)));
            ynew_i := to_integer(yw) + to_integer(shift_right(dy, integer(LEARN_SHIFT)));

            xnew := to_signed(sat16_i(xnew_i), 16);
            ynew := to_signed(sat16_i(ynew_i), 16);

            node_waddr <= resize(s1_id, NODE_AW);
            node_wdata <= pack_node(xnew, ynew);
            node_we    <= '1';

            -- error += best1 (L1)
            errv := get_err(ex);
            if (errv + resize(best1,31)) < errv then
              errv := (others => '1');
            else
              errv := errv + resize(best1,31);
            end if;

            err_waddr <= resize(s1_id, NODE_AW);
            err_wdata <= pack_err('1', errv);
            err_we    <= '1';

            st <= ST_STEP_NEXT;

          -- =========================
          -- NEXT / DONE
          -- =========================
          when ST_STEP_NEXT =>
            if sample_idx = to_unsigned(DATA_WORDS-1, 7) then
              sample_idx <= (others => '0');
            else
              sample_idx <= sample_idx + 1;
            end if;

            if steps_left <= 1 then
              st <= ST_DONE;
            else
              steps_left <= steps_left - 1;
              st <= ST_SAMP_SET;
            end if;

          when ST_DONE =>
            done_p <= '1';
            st <= ST_IDLE;

          when others =>
            st <= ST_IDLE;

        end case;

      end if;
    end if;
  end process;

end architecture;
