library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng is
  generic (
    MAX_NODES        : natural := 40;
    MAX_DEG          : natural := 6;    -- degree limit per node
    A_MAX            : natural := 50;   -- prune edge jika age > A_MAX
    DATA_WORDS       : natural := 100;  -- jumlah word32 dataset
    DONE_EVERY_STEPS : natural := 10;   -- gng_done pulse tiap N step
    INIT_X0          : integer := 200;
    INIT_Y0          : integer := 200;
    INIT_X1          : integer := 800;
    INIT_Y1          : integer := 800;
    LEARN_SHIFT      : natural := 4;    -- w += (x-w)>>LEARN_SHIFT
    ERR_SHIFT        : natural := 0     -- optional scaling error
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in  std_logic;

    -- dataset word32 sync read 1-cycle (dari mem_c top)
    data_raddr_o : out unsigned(6 downto 0);
    data_rdata_i : in  std_logic_vector(31 downto 0);

    gng_done_o : out std_logic; -- 1-cycle pulse saat selesai batch steps
    gng_busy_o : out std_logic;

    s1_id_o : out unsigned(5 downto 0);
    s2_id_o : out unsigned(5 downto 0)
  );
end entity;

architecture rtl of gng is

  -- ============================================================
  -- Node memories
  -- ============================================================
  type node_arr_t is array (0 to MAX_NODES-1) of signed(15 downto 0);
  type err_arr_t  is array (0 to MAX_NODES-1) of std_logic_vector(31 downto 0);
  -- mem_err(i)(31) = active flag
  -- mem_err(i)(30 downto 0) = unsigned error

  signal mem_x   : node_arr_t := (others => (others => '0'));
  signal mem_y   : node_arr_t := (others => (others => '0'));
  signal mem_err : err_arr_t  := (others => (others => '0'));

  -- degree count (0..MAX_DEG)
  type deg_arr_t is array (0 to MAX_NODES-1) of unsigned(3 downto 0);
  signal mem_deg : deg_arr_t := (others => (others => '0'));

  -- ============================================================
  -- Edge table = neighbor list (limited degree)
  -- nb_id(node)(slot), nb_age(node)(slot), nb_v(node)(slot)
  -- ============================================================
  type nb_id_row_t  is array (0 to MAX_DEG-1) of unsigned(5 downto 0);
  type nb_age_row_t is array (0 to MAX_DEG-1) of unsigned(7 downto 0);
  type nb_v_row_t   is array (0 to MAX_DEG-1) of std_logic;

  type nb_id_tab_t  is array (0 to MAX_NODES-1) of nb_id_row_t;
  type nb_age_tab_t is array (0 to MAX_NODES-1) of nb_age_row_t;
  type nb_v_tab_t   is array (0 to MAX_NODES-1) of nb_v_row_t;

  signal nb_id  : nb_id_tab_t  := (others => (others => (others => '0')));
  signal nb_age : nb_age_tab_t := (others => (others => (others => '0')));
  signal nb_v   : nb_v_tab_t   := (others => (others => '0'));

  -- ============================================================
  -- FSM
  -- ============================================================
  type st_t is (
    ST_IDLE,
    ST_INIT,        -- init hanya sekali setelah reset (pakai flag inited)

    -- read sample
    ST_SET_ADDR,
    ST_WAIT_RD,
    ST_LATCH_RD,

    -- find winner
    ST_FIND_INIT,
    ST_FIND_EVAL,
    ST_FIND_NEXT,

    -- edge handling AFTER find winner
    ST_EDGE_AGE_INIT,
    ST_EDGE_AGE_SLOT,
    ST_EDGE_RM_SCAN_INIT,
    ST_EDGE_RM_SCAN,

    ST_EDGE_CONNECT,   -- ensure edge s1-s2, set age=0

    -- update winner node + error
    ST_UPDATE_NODE,

    -- loop steps
    ST_STEP_NEXT,

    ST_DONE
  );
  signal st : st_t := ST_IDLE;

  -- ============================================================
  -- Control regs
  -- ============================================================
  signal start_d  : std_logic := '0';
  signal start_p  : std_logic := '0';

  signal inited   : std_logic := '0';

  signal sample_idx : unsigned(6 downto 0) := (others => '0');
  signal sx_i       : integer := 0;
  signal sy_i       : integer := 0;

  -- batch steps
  signal steps_left : integer := 0;

  -- find loop
  signal node_idx   : unsigned(5 downto 0) := (others => '0');
  signal best1_d    : integer := 2147483647;
  signal best2_d    : integer := 2147483647;
  signal s1_id      : unsigned(5 downto 0) := (others => '0');
  signal s2_id      : unsigned(5 downto 0) := (others => '0');

  -- edge aging scan
  signal edge_k     : integer range 0 to 255 := 0;
  signal rm_nb_id   : unsigned(5 downto 0) := (others => '0');
  signal rm_j       : integer range 0 to 255 := 0;

  signal done_pulse : std_logic := '0';

  -- ============================================================
  -- Helpers
  -- ============================================================
  function sat16(v : integer) return integer is
  begin
    if v > 32767 then return 32767;
    elsif v < -32768 then return -32768;
    else return v;
    end if;
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

begin

  -- outputs
  gng_done_o <= done_pulse;
  gng_busy_o <= '0' when st = ST_IDLE else '1';

  s1_id_o <= s1_id;
  s2_id_o <= s2_id;

  data_raddr_o <= sample_idx;

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

  -- main FSM
  process(clk_i)
    variable xi, yi : integer;
    variable wx, wy : integer;
    variable dx, dy : integer;
    variable d2     : integer;

    variable upd    : integer;

    variable err_u  : unsigned(30 downto 0);
    variable err_n  : unsigned(30 downto 0);

    variable ni     : integer;

    -- for EDGE_CONNECT
    variable found12 : boolean;
    variable idx_s1  : integer;
    variable idx_s2  : integer;
    variable empty_s1 : boolean;
    variable empty_s2 : boolean;
    variable emp1 : integer;
    variable emp2 : integer;

    -- helper
    variable age_next : unsigned(7 downto 0);
  begin
    if rising_edge(clk_i) then
      done_pulse <= '0';

      if rstn_i = '0' then
        st <= ST_IDLE;

        inited <= '0';

        sample_idx <= (others => '0');
        sx_i <= 0; sy_i <= 0;

        steps_left <= 0;

        node_idx <= (others => '0');
        best1_d  <= 2147483647;
        best2_d  <= 2147483647;
        s1_id    <= (others => '0');
        s2_id    <= (others => '0');

        mem_x   <= (others => (others => '0'));
        mem_y   <= (others => (others => '0'));
        mem_err <= (others => (others => '0'));
        mem_deg <= (others => (others => '0'));

        nb_id  <= (others => (others => (others => '0')));
        nb_age <= (others => (others => (others => '0')));
        nb_v   <= (others => (others => '0'));

        edge_k <= 0;
        rm_nb_id <= (others => '0');
        rm_j <= 0;

      else
        case st is

          when ST_IDLE =>
            if start_p = '1' then
              steps_left <= integer(DONE_EVERY_STEPS);
              if inited = '0' then
                st <= ST_INIT;
              else
                st <= ST_SET_ADDR;
              end if;
            end if;

          -- ======================================================
          -- INIT (sekali setelah reset)
          -- ======================================================
          when ST_INIT =>
            -- node 0,1 aktif
            mem_x(0) <= to_signed(sat16(INIT_X0), 16);
            mem_y(0) <= to_signed(sat16(INIT_Y0), 16);
            mem_err(0) <= pack_err('1', (others => '0'));

            mem_x(1) <= to_signed(sat16(INIT_X1), 16);
            mem_y(1) <= to_signed(sat16(INIT_Y1), 16);
            mem_err(1) <= pack_err('1', (others => '0'));

            -- lainnya inactive + deg=0
            for i in 2 to MAX_NODES-1 loop
              mem_err(i)(31) <= '0';
              mem_err(i)(30 downto 0) <= (others => '0');
              mem_deg(i) <= (others => '0');
            end loop;

            -- clear edge table + deg
            for i in 0 to MAX_NODES-1 loop
              mem_deg(i) <= (others => '0');
              for k in 0 to MAX_DEG-1 loop
                nb_v(i)(k) <= '0';
                nb_id(i)(k) <= (others => '0');
                nb_age(i)(k) <= (others => '0');
              end loop;
            end loop;

            inited <= '1';
            st <= ST_SET_ADDR;

          -- ======================================================
          -- READ sample (sync 1-cycle)
          -- ======================================================
          when ST_SET_ADDR =>
            st <= ST_WAIT_RD;

          when ST_WAIT_RD =>
            st <= ST_LATCH_RD;

          when ST_LATCH_RD =>
            xi := to_integer(signed(data_rdata_i(15 downto 0)));
            yi := to_integer(signed(data_rdata_i(31 downto 16)));
            sx_i <= xi;
            sy_i <= yi;
            st <= ST_FIND_INIT;

          -- ======================================================
          -- FIND winner init
          -- ======================================================
          when ST_FIND_INIT =>
            node_idx <= (others => '0');
            best1_d  <= 2147483647;
            best2_d  <= 2147483647;
            s1_id    <= (others => '0');
            s2_id    <= (others => '0');
            st <= ST_FIND_EVAL;

          when ST_FIND_EVAL =>
            ni := to_integer(node_idx);
            if ni < MAX_NODES then
              if is_active(mem_err(ni)) then
                wx := to_integer(mem_x(ni));
                wy := to_integer(mem_y(ni));
                dx := sx_i - wx;
                dy := sy_i - wy;
                d2 := (dx*dx) + (dy*dy);

                if d2 < best1_d then
                  best2_d <= best1_d;
                  s2_id   <= s1_id;
                  best1_d <= d2;
                  s1_id   <= node_idx;
                elsif d2 < best2_d then
                  if node_idx /= s1_id then
                    best2_d <= d2;
                    s2_id   <= node_idx;
                  end if;
                end if;
              end if;
              st <= ST_FIND_NEXT;
            else
              st <= ST_EDGE_AGE_INIT;
            end if;

          when ST_FIND_NEXT =>
            if node_idx = to_unsigned(MAX_NODES-1, node_idx'length) then
              st <= ST_EDGE_AGE_INIT;
            else
              node_idx <= node_idx + 1;
              st <= ST_FIND_EVAL;
            end if;

          -- ======================================================
          -- EDGE AGING: age semua edge yang terhubung ke s1
          -- prune jika age_next > A_MAX (remove both directions)
          -- ======================================================
          when ST_EDGE_AGE_INIT =>
            edge_k <= 0;
            st <= ST_EDGE_AGE_SLOT;

          when ST_EDGE_AGE_SLOT =>
            if edge_k >= MAX_DEG then
              st <= ST_EDGE_CONNECT;
            else
              ni := to_integer(s1_id);
              if nb_v(ni)(edge_k) = '1' then
                -- age + 1 (saturate 255)
                if nb_age(ni)(edge_k) = to_unsigned(255, 8) then
                  age_next := to_unsigned(255, 8);
                else
                  age_next := nb_age(ni)(edge_k) + 1;
                end if;

                -- prune?
                if to_integer(age_next) > integer(A_MAX) then
                  -- remove from s1
                  rm_nb_id <= nb_id(ni)(edge_k);
                  nb_v(ni)(edge_k) <= '0';
                  nb_age(ni)(edge_k) <= (others => '0');
                  nb_id(ni)(edge_k) <= (others => '0');

                  if mem_deg(ni) > 0 then
                    mem_deg(ni) <= mem_deg(ni) - 1;
                  end if;

                  -- now remove reciprocal in neighbor rm_nb_id
                  rm_j <= 0;
                  st <= ST_EDGE_RM_SCAN_INIT;
                else
                  nb_age(ni)(edge_k) <= age_next;
                  edge_k <= edge_k + 1;
                  st <= ST_EDGE_AGE_SLOT;
                end if;

              else
                edge_k <= edge_k + 1;
                st <= ST_EDGE_AGE_SLOT;
              end if;
            end if;

          when ST_EDGE_RM_SCAN_INIT =>
            st <= ST_EDGE_RM_SCAN;

          when ST_EDGE_RM_SCAN =>
            if rm_j >= MAX_DEG then
              -- done scanning neighbor; continue aging next slot
              edge_k <= edge_k + 1;
              st <= ST_EDGE_AGE_SLOT;
            else
              ni := to_integer(rm_nb_id);
              if nb_v(ni)(rm_j) = '1' and nb_id(ni)(rm_j) = s1_id then
                nb_v(ni)(rm_j) <= '0';
                nb_age(ni)(rm_j) <= (others => '0');
                nb_id(ni)(rm_j) <= (others => '0');
                if mem_deg(ni) > 0 then
                  mem_deg(ni) <= mem_deg(ni) - 1;
                end if;
              end if;
              rm_j <= rm_j + 1;
              st <= ST_EDGE_RM_SCAN;
            end if;

          -- ======================================================
          -- EDGE CONNECT: pastikan edge s1-s2 ada, age=0
          -- - jika sudah ada: set age=0 (dua arah)
          -- - jika belum ada: add jika ada slot kosong di KEDUA sisi
          -- ======================================================
          when ST_EDGE_CONNECT =>
            ni := to_integer(s1_id);

            found12 := false;
            idx_s1 := -1;
            idx_s2 := -1;

            empty_s1 := false;
            empty_s2 := false;
            emp1 := -1;
            emp2 := -1;

            -- scan list s1 untuk s2 / empty
            for k in 0 to MAX_DEG-1 loop
              if nb_v(ni)(k) = '1' then
                if nb_id(ni)(k) = s2_id then
                  found12 := true;
                  idx_s1 := k;
                end if;
              else
                if not empty_s1 then
                  empty_s1 := true;
                  emp1 := k;
                end if;
              end if;
            end loop;

            -- scan list s2 untuk s1 / empty
            ni := to_integer(s2_id);
            for k in 0 to MAX_DEG-1 loop
              if nb_v(ni)(k) = '1' then
                if nb_id(ni)(k) = s1_id then
                  found12 := true;
                  idx_s2 := k;
                end if;
              else
                if not empty_s2 then
                  empty_s2 := true;
                  emp2 := k;
                end if;
              end if;
            end loop;

            if idx_s1 /= -1 and idx_s2 /= -1 then
              -- edge sudah ada dua arah -> reset age
              nb_age(to_integer(s1_id))(idx_s1) <= (others => '0');
              nb_age(to_integer(s2_id))(idx_s2) <= (others => '0');
              st <= ST_UPDATE_NODE;

            else
              -- edge belum lengkap -> coba add (harus ada slot kosong di dua sisi)
              if empty_s1 and empty_s2 then
                nb_v(to_integer(s1_id))(emp1) <= '1';
                nb_id(to_integer(s1_id))(emp1) <= s2_id;
                nb_age(to_integer(s1_id))(emp1) <= (others => '0');

                nb_v(to_integer(s2_id))(emp2) <= '1';
                nb_id(to_integer(s2_id))(emp2) <= s1_id;
                nb_age(to_integer(s2_id))(emp2) <= (others => '0');

                mem_deg(to_integer(s1_id)) <= mem_deg(to_integer(s1_id)) + 1;
                mem_deg(to_integer(s2_id)) <= mem_deg(to_integer(s2_id)) + 1;
              else
                -- degree penuh -> untuk versi awal ini, kita skip add (biar konsisten + simpel)
                -- nanti bisa ditingkatkan: replace-oldest
                null;
              end if;

              st <= ST_UPDATE_NODE;
            end if;

          -- ======================================================
          -- UPDATE winner node + error
          -- ======================================================
          when ST_UPDATE_NODE =>
            ni := to_integer(s1_id);

            wx := to_integer(mem_x(ni));
            wy := to_integer(mem_y(ni));

            dx := sx_i - wx;
            dy := sy_i - wy;

            upd := dx / (2**integer(LEARN_SHIFT));
            mem_x(ni) <= to_signed(sat16(wx + upd), 16);

            upd := dy / (2**integer(LEARN_SHIFT));
            mem_y(ni) <= to_signed(sat16(wy + upd), 16);

            -- error += best1_d (optional shift)
            err_u := get_err(mem_err(ni));

            d2 := best1_d;
            if ERR_SHIFT > 0 then
              d2 := d2 / (2**integer(ERR_SHIFT));
            end if;
            if d2 < 0 then d2 := 0; end if;

            if (unsigned(err_u) + to_unsigned(d2, 31)) > to_unsigned(2**31-1, 31) then
              err_n := (others => '1');
            else
              err_n := unsigned(err_u) + to_unsigned(d2, 31);
            end if;

            mem_err(ni) <= pack_err('1', err_n);

            st <= ST_STEP_NEXT;

          -- ======================================================
          -- STEP NEXT: dataset index + steps counter
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
              st <= ST_SET_ADDR;
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
