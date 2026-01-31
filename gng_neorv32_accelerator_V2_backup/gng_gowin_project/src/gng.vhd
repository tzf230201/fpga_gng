library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng is
  generic (
    MAX_NODES   : natural := 40;
    DATA_WORDS  : natural := 100;

    INIT_X0     : integer := 200;
    INIT_Y0     : integer := 200;
    INIT_X1     : integer := 800;
    INIT_Y1     : integer := 800;

    -- learning rate (shift right)
    EPS_B_SHIFT : natural := 4; -- winner
    EPS_N_SHIFT : natural := 6; -- neighbors

    -- edge aging
    EDGE_A_MAX  : natural := 50; -- max age (real). stored as age_code=age (1..A_MAX+1)

    -- error decay: err <- err - (err >> BETA_SHIFT)
    BETA_SHIFT  : natural := 8
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;
    start_i : in  std_logic;

    -- dataset BRAM_C read (sync 1-cycle outside)
    data_raddr_o : out unsigned(6 downto 0);
    data_rdata_i : in  std_logic_vector(31 downto 0);

    gng_done_o : out std_logic;
    gng_busy_o : out std_logic;

    -- 8-bit node IDs
    s1_id_o : out unsigned(7 downto 0);
    s2_id_o : out unsigned(7 downto 0);

    -- debug taps (0xA1)
    dbg_node_raddr_i : in  unsigned(7 downto 0);
    dbg_node_rdata_o : out std_logic_vector(31 downto 0);

    dbg_err_raddr_i  : in  unsigned(7 downto 0);
    dbg_err_rdata_o  : out std_logic_vector(31 downto 0);

    -- EDGE debug (half adjacency) address 13-bit
    dbg_edge_raddr_i : in  unsigned(12 downto 0);
    dbg_edge_rdata_o : out std_logic_vector(15 downto 0);

    -- winner-log tap (0xB1)
    dbg_win_raddr_i  : in  unsigned(6 downto 0);           -- 0..99
    dbg_win_rdata_o  : out std_logic_vector(15 downto 0)   -- [7:0]=s1 [15:8]=s2
  );
end entity;

architecture rtl of gng is
  subtype node_id_t is unsigned(7 downto 0);

  --------------------------------------------------------------------------
  -- constants: half adjacency size
  --------------------------------------------------------------------------
  function calc_edges(n : natural) return natural is
  begin
    return (n * (n - 1)) / 2;
  end function;

  constant EDGE_COUNT : natural := calc_edges(MAX_NODES); -- 40 -> 780

  -- For MAX_NODES=40, EDGE_COUNT=780 fits in 10-bit address (0..1023).
  constant EDGE_AW_RAM    : natural := 10;
  constant EDGE_DEPTH_RAM : natural := 2**EDGE_AW_RAM;

  -- IMPORTANT: Gowin parser fix (avoid "unsigned(EDGE_AW_RAM-1 downto 0)" directly)
  subtype edge_addr_t is unsigned(EDGE_AW_RAM-1 downto 0);

  --------------------------------------------------------------------------
  -- base table for half-adj indexing (no multiply/div)
  -- base(i) = sum_{k=0..i-1} (N-1-k)
  -- idx(i<j) = base(i) + (j-i-1)
  --------------------------------------------------------------------------
  type base_t is array (0 to MAX_NODES-1) of edge_addr_t;

  function make_base return base_t is
    variable b   : base_t;
    variable acc : integer := 0;
    variable i   : integer;
  begin
    for i in 0 to MAX_NODES-1 loop
      b(i) := to_unsigned(acc, EDGE_AW_RAM);
      acc  := acc + (integer(MAX_NODES) - 1 - i);
    end loop;
    return b;
  end function;

  constant EDGE_BASE : base_t := make_base;

  function edge_idx(i_u : node_id_t; j_u : node_id_t) return edge_addr_t is
    variable i, j   : integer;
    variable lo, hi : integer;
    variable basei  : integer;
    variable off    : integer;
    variable idxi   : integer;
  begin
    i := to_integer(i_u);
    j := to_integer(j_u);

    if i = j then
      return to_unsigned(0, EDGE_AW_RAM);
    end if;

    if i < j then
      lo := i; hi := j;
    else
      lo := j; hi := i;
    end if;

    basei := to_integer(EDGE_BASE(lo));
    off   := (hi - lo - 1);
    idxi  := basei + off;

    return to_unsigned(idxi, EDGE_AW_RAM);
  end function;

  --------------------------------------------------------------------------
  -- memories
  --------------------------------------------------------------------------
  type node_mem_t is array (0 to MAX_NODES-1) of std_logic_vector(31 downto 0);
  signal node_mem : node_mem_t := (others => (others => '0')); -- [15:0]=x, [31:16]=y

  type err_mem_t is array (0 to MAX_NODES-1) of unsigned(30 downto 0);
  signal err_mem : err_mem_t := (others => (others => '0'));

  signal active_mask : std_logic_vector(MAX_NODES-1 downto 0) := (others => '0');
  signal node_count  : node_id_t := (others => '0');

  type win_mem_t is array (0 to DATA_WORDS-1) of std_logic_vector(15 downto 0);
  signal win_mem : win_mem_t := (others => (others => '0')); -- [7:0]=s1 [15:8]=s2

  --------------------------------------------------------------------------
  -- EDGE RAM: store age_code (0=no edge, 1..A_MAX+1)
  --------------------------------------------------------------------------
  type edge_ram_t is array (0 to EDGE_DEPTH_RAM-1) of std_logic_vector(7 downto 0);
  signal edge_ram : edge_ram_t := (others => (others => '0'));

  signal edge_a_addr : edge_addr_t := (others => '0');
  signal edge_a_din  : std_logic_vector(7 downto 0) := (others => '0');
  signal edge_a_we   : std_logic := '0';
  signal edge_a_dout : std_logic_vector(7 downto 0) := (others => '0');

  signal edge_b_addr : edge_addr_t := (others => '0');
  signal edge_b_dout : std_logic_vector(7 downto 0) := (others => '0');

  --------------------------------------------------------------------------
  -- start pulse
  --------------------------------------------------------------------------
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  --------------------------------------------------------------------------
  -- sample
  --------------------------------------------------------------------------
  signal step_idx : unsigned(6 downto 0) := (others => '0');
  signal x_s      : signed(15 downto 0) := (others => '0');
  signal y_s      : signed(15 downto 0) := (others => '0');

  --------------------------------------------------------------------------
  -- FSM signals
  --------------------------------------------------------------------------
  type st_t is (
    ST_IDLE,
    ST_INIT_CLR_EDGES,
    ST_INIT_CLR_NODES,
    ST_INIT_SET_N0,
    ST_INIT_SET_N1,

    ST_RD_SET, ST_RD_WAIT, ST_RD_LATCH,

    ST_W_INIT, ST_W_READ, ST_W_EVAL, ST_W_NEXT, ST_W_DONE,

    ST_E_CONN,
    ST_E_INIT, ST_E_RD, ST_E_EVAL, ST_E_NEXT, ST_E_DONE,

    ST_ERR_ACC,

    ST_MW_RD, ST_MW_WR,

    ST_MN_INIT, ST_MN_EDGE_RD, ST_MN_EDGE_EVAL,
    ST_MN_NODE_RD, ST_MN_NODE_WR, ST_MN_NEXT, ST_MN_DONE,

    ST_DECAY_INIT, ST_DECAY_STEP, ST_DECAY_NEXT, ST_DECAY_DONE,

    ST_LOG,
    ST_NEXT,
    ST_FINISH
  );
  signal st : st_t := ST_IDLE;

  signal eclr  : edge_addr_t := (others => '0');
  signal i_idx : node_id_t := (others => '0');
  signal j_idx : node_id_t := (others => '0');

  signal node_reg : std_logic_vector(31 downto 0) := (others => '0');

  -- winner result (L2^2)
  signal best_id   : node_id_t := (others => '0');
  signal second_id : node_id_t := (others => '0');
  signal best_d2   : unsigned(32 downto 0) := (others => '1');
  signal second_d2 : unsigned(32 downto 0) := (others => '1');

  signal s1_lat : node_id_t := (others => '0');
  signal s2_lat : node_id_t := (others => '0');
  signal d2_lat : unsigned(32 downto 0) := (others => '0');

begin
  --------------------------------------------------------------------------
  -- dataset addr
  --------------------------------------------------------------------------
  data_raddr_o <= step_idx;

  --------------------------------------------------------------------------
  -- start edge detect
  --------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i='0' then
        start_d <= '0';
        start_p <= '0';
      else
        start_p <= start_i and (not start_d);
        start_d <= start_i;
      end if;
    end if;
  end process;

  --------------------------------------------------------------------------
  -- EDGE RAM dual-port (explicit write-first to avoid Gowin weird WRITE_MODE)
  --------------------------------------------------------------------------
  edge_b_addr <= unsigned(dbg_edge_raddr_i(EDGE_AW_RAM-1 downto 0));

  process(clk_i)
    variable a_ai : integer;
    variable a_bi : integer;
  begin
    if rising_edge(clk_i) then
      a_ai := to_integer(edge_a_addr);
      a_bi := to_integer(edge_b_addr);

      -- port A
      if edge_a_we='1' then
        edge_ram(a_ai) <= edge_a_din;
        edge_a_dout    <= edge_a_din; -- write-first
      else
        edge_a_dout    <= edge_ram(a_ai);
      end if;

      -- port B read (if collision with A write => show new data)
      if (edge_a_we='1') and (a_ai = a_bi) then
        edge_b_dout <= edge_a_din;
      else
        edge_b_dout <= edge_ram(a_bi);
      end if;
    end if;
  end process;

  --------------------------------------------------------------------------
  -- MAIN FSM
  --------------------------------------------------------------------------
  process(clk_i)
    variable nx, ny : signed(15 downto 0);
    variable dx17, dy17 : signed(16 downto 0);
    variable dxu, dyu   : unsigned(16 downto 0);
    variable dx2_34, dy2_34 : unsigned(33 downto 0);
    variable dx2_33, dy2_33 : unsigned(32 downto 0);
    variable dist2 : unsigned(32 downto 0);

    variable olde  : unsigned(30 downto 0);
    variable add31 : unsigned(30 downto 0);
    variable sum32 : unsigned(31 downto 0);

    variable wx, wy : signed(15 downto 0);
    variable delx, dely : signed(15 downto 0);

    variable age_u    : unsigned(7 downto 0);
    variable age_next : unsigned(7 downto 0);
    variable amax_code: unsigned(7 downto 0);

    variable idxi : integer;
  begin
    if rising_edge(clk_i) then
      gng_done_o <= '0';
      edge_a_we  <= '0';

      if rstn_i='0' then
        st <= ST_IDLE;
        step_idx <= (others => '0');
        node_count <= (others => '0');
        s1_id_o <= (others => '0');
        s2_id_o <= (others => '0');

      else
        case st is
          ------------------------------------------------------------------
          -- IDLE -> init when start_p
          ------------------------------------------------------------------
          when ST_IDLE =>
            if start_p='1' then
              eclr <= (others => '0');
              st <= ST_INIT_CLR_EDGES;
            end if;

          ------------------------------------------------------------------
          -- clear EDGE RAM (only first EDGE_COUNT entries)
          ------------------------------------------------------------------
          when ST_INIT_CLR_EDGES =>
            if EDGE_COUNT = 0 then
              i_idx <= (others => '0');
              st <= ST_INIT_CLR_NODES;

            elsif to_integer(eclr) < integer(EDGE_COUNT) then
              edge_a_addr <= eclr;
              edge_a_din  <= x"00";
              edge_a_we   <= '1';
              eclr <= eclr + 1;

            else
              i_idx <= (others => '0');
              st <= ST_INIT_CLR_NODES;
            end if;

          ------------------------------------------------------------------
          -- clear nodes/errors/mask
          ------------------------------------------------------------------
          when ST_INIT_CLR_NODES =>
            if to_integer(i_idx) < integer(MAX_NODES) then
              node_mem(to_integer(i_idx)) <= (others => '0');
              err_mem(to_integer(i_idx))  <= (others => '0');
              active_mask(to_integer(i_idx)) <= '0';
              i_idx <= i_idx + 1;
            else
              st <= ST_INIT_SET_N0;
            end if;

          ------------------------------------------------------------------
          -- set node 0 & 1
          ------------------------------------------------------------------
          when ST_INIT_SET_N0 =>
            if MAX_NODES > 0 then
              node_mem(0) <= std_logic_vector(to_signed(INIT_Y0,16)) & std_logic_vector(to_signed(INIT_X0,16));
              active_mask(0) <= '1';
              err_mem(0) <= (others => '0');
            end if;
            st <= ST_INIT_SET_N1;

          when ST_INIT_SET_N1 =>
            if MAX_NODES > 1 then
              node_mem(1) <= std_logic_vector(to_signed(INIT_Y1,16)) & std_logic_vector(to_signed(INIT_X1,16));
              active_mask(1) <= '1';
              err_mem(1) <= (others => '0');
            end if;

            node_count <= to_unsigned(2,8);
            step_idx   <= (others => '0');
            st <= ST_RD_SET;

          ------------------------------------------------------------------
          -- read sample (sync 1-cycle outside)
          ------------------------------------------------------------------
          when ST_RD_SET =>
            st <= ST_RD_WAIT;

          when ST_RD_WAIT =>
            st <= ST_RD_LATCH;

          when ST_RD_LATCH =>
            x_s <= signed(data_rdata_i(15 downto 0));
            y_s <= signed(data_rdata_i(31 downto 16));
            st  <= ST_W_INIT;

          ------------------------------------------------------------------
          -- winner search init
          ------------------------------------------------------------------
          when ST_W_INIT =>
            i_idx <= (others => '0');
            best_id <= (others => '0');
            second_id <= (others => '0');
            best_d2 <= (others => '1');
            second_d2 <= (others => '1');
            st <= ST_W_READ;

          when ST_W_READ =>
            node_reg <= node_mem(to_integer(i_idx));
            st <= ST_W_EVAL;

          when ST_W_EVAL =>
            if (to_integer(i_idx) < to_integer(node_count)) and (active_mask(to_integer(i_idx))='1') then
              nx := signed(node_reg(15 downto 0));
              ny := signed(node_reg(31 downto 16));

              dx17 := resize(x_s - nx, 17);
              dy17 := resize(y_s - ny, 17);

              -- abs to unsigned 17
              if dx17(16)='1' then dxu := unsigned(-dx17); else dxu := unsigned(dx17); end if;
              if dy17(16)='1' then dyu := unsigned(-dy17); else dyu := unsigned(dy17); end if;

              dx2_34 := dxu * dxu;  -- 17x17 -> 34-bit
              dy2_34 := dyu * dyu;

              dx2_33 := resize(dx2_34, 33); -- safe (top bits zero)
              dy2_33 := resize(dy2_34, 33);

              dist2 := dx2_33 + dy2_33; -- 33-bit

              if dist2 < best_d2 then
                second_d2 <= best_d2;
                second_id <= best_id;
                best_d2   <= dist2;
                best_id   <= i_idx;

              elsif dist2 < second_d2 then
                if i_idx /= best_id then
                  second_d2 <= dist2;
                  second_id <= i_idx;
                end if;
              end if;
            end if;

            st <= ST_W_NEXT;

          when ST_W_NEXT =>
            if i_idx = node_count - 1 then
              st <= ST_W_DONE;
            else
              i_idx <= i_idx + 1;
              st <= ST_W_READ;
            end if;

          when ST_W_DONE =>
            s1_lat <= best_id;
            s2_lat <= second_id;
            d2_lat <= best_d2;

            s1_id_o <= best_id;
            s2_id_o <= second_id;

            st <= ST_E_CONN;

          ------------------------------------------------------------------
          -- connect/reset edge(s1,s2) age_code=1
          ------------------------------------------------------------------
          when ST_E_CONN =>
            if EDGE_COUNT > 0 then
              edge_a_addr <= edge_idx(s1_lat, s2_lat);
              edge_a_din  <= x"01";
              edge_a_we   <= '1';
            end if;
            j_idx <= (others => '0');
            st <= ST_E_INIT;

          ------------------------------------------------------------------
          -- edge aging for edges from s1 (except s2), only if age_code!=0
          ------------------------------------------------------------------
          when ST_E_INIT =>
            j_idx <= (others => '0');
            st <= ST_E_RD;

          when ST_E_RD =>
            if to_integer(j_idx) >= to_integer(node_count) then
              st <= ST_E_DONE;

            elsif (j_idx = s1_lat) or (j_idx = s2_lat) then
              st <= ST_E_NEXT;

            else
              edge_a_addr <= edge_idx(s1_lat, j_idx);
              st <= ST_E_EVAL;
            end if;

          when ST_E_EVAL =>
            age_u := unsigned(edge_a_dout);

            if age_u /= 0 then
              age_next := age_u + 1;

              if EDGE_A_MAX >= 254 then
                amax_code := to_unsigned(255,8);
              else
                amax_code := to_unsigned(EDGE_A_MAX + 1, 8);
              end if;

              if age_next > amax_code then
                age_next := to_unsigned(0,8); -- remove
              end if;

              edge_a_addr <= edge_idx(s1_lat, j_idx);
              edge_a_din  <= std_logic_vector(age_next);
              edge_a_we   <= '1';
            end if;

            st <= ST_E_NEXT;

          when ST_E_NEXT =>
            if j_idx = node_count - 1 then
              st <= ST_E_DONE;
            else
              j_idx <= j_idx + 1;
              st <= ST_E_RD;
            end if;

          when ST_E_DONE =>
            st <= ST_ERR_ACC;

          ------------------------------------------------------------------
          -- accumulate error: err[s1] += d2_lat (saturate 31-bit)
          ------------------------------------------------------------------
          when ST_ERR_ACC =>
            idxi := to_integer(s1_lat);
            if (idxi >= 0) and (idxi < integer(MAX_NODES)) and (active_mask(idxi)='1') then
              olde := err_mem(idxi);

              -- clamp add to 31-bit
              if d2_lat(32 downto 31) /= "00" then
                add31 := (others => '1');
              else
                add31 := d2_lat(30 downto 0);
              end if;

              sum32 := ('0' & olde) + ('0' & add31);

              if sum32(31)='1' then
                err_mem(idxi) <= (others => '1');
              else
                err_mem(idxi) <= sum32(30 downto 0);
              end if;
            end if;

            st <= ST_MW_RD;

          ------------------------------------------------------------------
          -- move winner
          ------------------------------------------------------------------
          when ST_MW_RD =>
            node_reg <= node_mem(to_integer(s1_lat));
            st <= ST_MW_WR;

          when ST_MW_WR =>
            wx := signed(node_reg(15 downto 0));
            wy := signed(node_reg(31 downto 16));

            delx := shift_right((x_s - wx), EPS_B_SHIFT);
            dely := shift_right((y_s - wy), EPS_B_SHIFT);

            node_mem(to_integer(s1_lat)) <= std_logic_vector(wy + dely) & std_logic_vector(wx + delx);
            st <= ST_MN_INIT;

          ------------------------------------------------------------------
          -- move neighbors: if edge(s1,j)!=0 then update
          ------------------------------------------------------------------
          when ST_MN_INIT =>
            j_idx <= (others => '0');
            st <= ST_MN_EDGE_RD;

          when ST_MN_EDGE_RD =>
            if to_integer(j_idx) >= to_integer(node_count) then
              st <= ST_MN_DONE;

            elsif (j_idx = s1_lat) or (active_mask(to_integer(j_idx))='0') then
              st <= ST_MN_NEXT;

            else
              edge_a_addr <= edge_idx(s1_lat, j_idx);
              st <= ST_MN_EDGE_EVAL;
            end if;

          when ST_MN_EDGE_EVAL =>
            if unsigned(edge_a_dout) = 0 then
              st <= ST_MN_NEXT;
            else
              st <= ST_MN_NODE_RD;
            end if;

          when ST_MN_NODE_RD =>
            node_reg <= node_mem(to_integer(j_idx));
            st <= ST_MN_NODE_WR;

          when ST_MN_NODE_WR =>
            wx := signed(node_reg(15 downto 0));
            wy := signed(node_reg(31 downto 16));

            delx := shift_right((x_s - wx), EPS_N_SHIFT);
            dely := shift_right((y_s - wy), EPS_N_SHIFT);

            node_mem(to_integer(j_idx)) <= std_logic_vector(wy + dely) & std_logic_vector(wx + delx);
            st <= ST_MN_NEXT;

          when ST_MN_NEXT =>
            if j_idx = node_count - 1 then
              st <= ST_MN_DONE;
            else
              j_idx <= j_idx + 1;
              st <= ST_MN_EDGE_RD;
            end if;

          when ST_MN_DONE =>
            st <= ST_DECAY_INIT;

          ------------------------------------------------------------------
          -- decay all error
          ------------------------------------------------------------------
          when ST_DECAY_INIT =>
            i_idx <= (others => '0');
            st <= ST_DECAY_STEP;

          when ST_DECAY_STEP =>
            if to_integer(i_idx) < to_integer(node_count) then
              idxi := to_integer(i_idx);
              if active_mask(idxi)='1' then
                err_mem(idxi) <= err_mem(idxi) - shift_right(err_mem(idxi), BETA_SHIFT);
              end if;
              st <= ST_DECAY_NEXT;
            else
              st <= ST_DECAY_DONE;
            end if;

          when ST_DECAY_NEXT =>
            i_idx <= i_idx + 1;
            st <= ST_DECAY_STEP;

          when ST_DECAY_DONE =>
            st <= ST_LOG;

          ------------------------------------------------------------------
          -- log winners
          ------------------------------------------------------------------
          when ST_LOG =>
            win_mem(to_integer(step_idx)) <= std_logic_vector(s2_lat) & std_logic_vector(s1_lat);
            st <= ST_NEXT;

          ------------------------------------------------------------------
          -- next sample
          ------------------------------------------------------------------
          when ST_NEXT =>
            if step_idx = to_unsigned(DATA_WORDS-1, step_idx'length) then
              st <= ST_FINISH;
            else
              step_idx <= step_idx + 1;
              st <= ST_RD_SET;
            end if;

          when ST_FINISH =>
            gng_done_o <= '1';
            st <= ST_IDLE;

          when others =>
            st <= ST_IDLE;
        end case;
      end if;
    end if;
  end process;

  gng_busy_o <= '0' when st = ST_IDLE else '1';

  --------------------------------------------------------------------------
  -- Debug taps (sync 1-cycle style)
  --------------------------------------------------------------------------
  process(clk_i)
    variable a  : integer;
    variable ew : std_logic_vector(31 downto 0);
    variable age : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk_i) then
      -- node
      a := to_integer(dbg_node_raddr_i);
      if (a >= 0) and (a < integer(MAX_NODES)) then
        dbg_node_rdata_o <= node_mem(a);
      else
        dbg_node_rdata_o <= (others => '0');
      end if;

      -- err: [31]=active, [30:0]=err
      a := to_integer(dbg_err_raddr_i);
      if (a >= 0) and (a < integer(MAX_NODES)) then
        ew := (others => '0');
        ew(31) := active_mask(a);
        ew(30 downto 0) := std_logic_vector(err_mem(a));
        dbg_err_rdata_o <= ew;
      else
        dbg_err_rdata_o <= (others => '0');
      end if;

      -- edge debug: show age_code in low byte
      age := edge_b_dout;
      dbg_edge_rdata_o <= (15 downto 8 => '0') & age;

      -- win log
      a := to_integer(dbg_win_raddr_i);
      if (a >= 0) and (a < integer(DATA_WORDS)) then
        dbg_win_rdata_o <= win_mem(a);
      else
        dbg_win_rdata_o <= (others => '0');
      end if;
    end if;
  end process;

end architecture;
