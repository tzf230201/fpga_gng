library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng is
  generic (
    MAX_NODES        : natural := 40;

    DATA_WORDS       : natural := 100;
    DONE_EVERY_STEPS : natural := 10; -- (unused in this debug-only version)

    INIT_X0          : integer := 200;
    INIT_Y0          : integer := 200;
    INIT_X1          : integer := 800;
    INIT_Y1          : integer := 800;

    EDGE_A_MAX       : natural := 50
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;
    start_i : in  std_logic;

    -- dataset BRAM_C read (sync 1-cycle)
    data_raddr_o : out unsigned(6 downto 0);
    data_rdata_i : in  std_logic_vector(31 downto 0);

    gng_done_o : out std_logic;
    gng_busy_o : out std_logic;

    -- 8-bit node IDs
    s1_id_o : out unsigned(7 downto 0);
    s2_id_o : out unsigned(7 downto 0);

    -- debug taps for 0xA1 dumper
    dbg_node_raddr_i : in  unsigned(7 downto 0);
    dbg_node_rdata_o : out std_logic_vector(31 downto 0);

    dbg_err_raddr_i  : in  unsigned(7 downto 0);
    dbg_err_rdata_o  : out std_logic_vector(31 downto 0);

    -- EDGE debug (half adjacency) address 13-bit
    dbg_edge_raddr_i : in  unsigned(12 downto 0);
    dbg_edge_rdata_o : out std_logic_vector(15 downto 0);

    -- winner-log tap for 0xB1 dumper
    dbg_win_raddr_i  : in  unsigned(6 downto 0);           -- 0..99
    dbg_win_rdata_o  : out std_logic_vector(15 downto 0)   -- [7:0]=s1 [15:8]=s2
  );
end entity;

architecture rtl of gng is

  subtype node_id_t is unsigned(7 downto 0);

  type st_t is (
    ST_IDLE,
    ST_RD_SET, ST_RD_WAIT, ST_RD_LATCH,
    ST_WF_START, ST_WF_WAIT,
    ST_EA_START, ST_EA_WAIT,
    ST_NEXT, ST_FINISH
  );
  signal st : st_t := ST_IDLE;

  signal step_idx : unsigned(6 downto 0) := (others => '0');
  signal x_s      : signed(15 downto 0) := (others => '0');
  signal y_s      : signed(15 downto 0) := (others => '0');

  -- start edge detect
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  -- winner finder
  signal wf_start : std_logic := '0';
  signal wf_done  : std_logic;
  signal wf_busy  : std_logic;
  signal wf_s1    : node_id_t;
  signal wf_s2    : node_id_t;
  signal wf_d1    : unsigned(32 downto 0); -- L2^2

  signal wf_node_raddr : node_id_t := (others => '0');
  signal wf_node_rdata : std_logic_vector(31 downto 0) := (others => '0');

  function init_active_mask return std_logic_vector is
    variable m : std_logic_vector(MAX_NODES-1 downto 0) := (others => '0');
  begin
    if MAX_NODES > 0 then m(0) := '1'; end if;
    if MAX_NODES > 1 then m(1) := '1'; end if;
    return m;
  end function;

  signal node_count  : node_id_t := to_unsigned(2,8);
  signal active_mask : std_logic_vector(MAX_NODES-1 downto 0) := init_active_mask;

  -- winner log
  type win_mem_t is array (0 to DATA_WORDS-1) of std_logic_vector(15 downto 0);
  signal win_mem : win_mem_t := (others => (others => '0'));

  -- latch winners + distance for later stages
  signal s1_lat : node_id_t := (others => '0');
  signal s2_lat : node_id_t := (others => '0');
  signal d1_lat : unsigned(32 downto 0) := (others => '0');

  -- edge aging
  signal edge_start : std_logic := '0';
  signal edge_done  : std_logic;
  signal edge_busy  : std_logic;

  -- error memory: bit31=active, bit30..0=error accumulator (saturated)
  type err_mem_t is array (0 to MAX_NODES-1) of std_logic_vector(31 downto 0);
  signal err_mem : err_mem_t := (others => (others => '0'));

  -- error write request (FSM -> err_mem single-writer)
  signal err_we  : std_logic := '0';
  signal err_wid : node_id_t := (others => '0');
  signal err_add : unsigned(32 downto 0) := (others => '0'); -- d1 (L2^2)

  function pack_xy(xi : integer; yi : integer) return std_logic_vector is
    variable x16 : signed(15 downto 0);
    variable y16 : signed(15 downto 0);
    variable w   : std_logic_vector(31 downto 0);
  begin
    x16 := to_signed(xi,16);
    y16 := to_signed(yi,16);
    w(15 downto 0)  := std_logic_vector(x16);
    w(31 downto 16) := std_logic_vector(y16);
    return w;
  end function;

begin

  ---------------------------------------------------------------------------
  -- start pulse
  ---------------------------------------------------------------------------
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

  ---------------------------------------------------------------------------
  -- active_mask/node_count init on reset AND on start
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i='0' then
        active_mask <= init_active_mask;
        node_count  <= to_unsigned(2,8);
      elsif start_p='1' then
        active_mask <= init_active_mask;
        node_count  <= to_unsigned(2,8);
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- dataset addr (sync BRAM outside)
  ---------------------------------------------------------------------------
  data_raddr_o <= step_idx;

  ---------------------------------------------------------------------------
  -- node "ROM" for winner finder (sync 1-cycle)
  ---------------------------------------------------------------------------
  process(clk_i)
    variable a : integer;
  begin
    if rising_edge(clk_i) then
      a := to_integer(wf_node_raddr);
      if a = 0 then
        wf_node_rdata <= pack_xy(INIT_X0, INIT_Y0);
      elsif a = 1 then
        wf_node_rdata <= pack_xy(INIT_X1, INIT_Y1);
      else
        wf_node_rdata <= (others => '0');
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- winner finder (L2^2)
  ---------------------------------------------------------------------------
  u_find : entity work.gng_find_winner
    generic map (
      MAX_NODES => MAX_NODES
    )
    port map (
      clk_i  => clk_i,
      rstn_i => rstn_i,

      start_i => wf_start,
      busy_o  => wf_busy,
      done_o  => wf_done,

      x_i => x_s,
      y_i => y_s,

      node_count_i  => node_count,
      active_mask_i => active_mask,

      node_raddr_o => wf_node_raddr,
      node_rdata_i => wf_node_rdata,

      s1_o => wf_s1,
      s2_o => wf_s2,
      d1_o => wf_d1
    );

  ---------------------------------------------------------------------------
  -- edge aging
  ---------------------------------------------------------------------------
  u_edge : entity work.edge_aging
    generic map (
      MAX_NODES => MAX_NODES,
      EDGE_AW   => 13,
      AGE_W     => 8,
      A_MAX     => EDGE_A_MAX
    )
    port map (
      clk_i  => clk_i,
      rstn_i => rstn_i,

      start_i => edge_start,

      s1_i => s1_lat,
      s2_i => s2_lat,

      node_count_i => node_count,

      busy_o => edge_busy,
      done_o => edge_done,

      dbg_edge_raddr_i => dbg_edge_raddr_i,
      dbg_edge_rdata_o => dbg_edge_rdata_o
    );

  ---------------------------------------------------------------------------
  -- main FSM (NO direct write to err_mem!)
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      wf_start   <= '0';
      edge_start <= '0';
      gng_done_o <= '0';
      err_we     <= '0';

      if rstn_i='0' then
        st       <= ST_IDLE;
        step_idx <= (others => '0');
        x_s      <= (others => '0');
        y_s      <= (others => '0');
        s1_id_o  <= (others => '0');
        s2_id_o  <= (others => '0');
        s1_lat   <= (others => '0');
        s2_lat   <= (others => '0');
        d1_lat   <= (others => '0');
        err_wid  <= (others => '0');
        err_add  <= (others => '0');

      else
        case st is

          when ST_IDLE =>
            if start_p='1' then
              step_idx <= (others => '0');
              st <= ST_RD_SET;
            end if;

          when ST_RD_SET =>
            st <= ST_RD_WAIT;

          when ST_RD_WAIT =>
            st <= ST_RD_LATCH;

          when ST_RD_LATCH =>
            x_s <= signed(data_rdata_i(15 downto 0));
            y_s <= signed(data_rdata_i(31 downto 16));
            st  <= ST_WF_START;

          when ST_WF_START =>
            wf_start <= '1';
            st <= ST_WF_WAIT;

          when ST_WF_WAIT =>
            if wf_done='1' then
              -- latch winners + distance
              s1_lat  <= wf_s1;
              s2_lat  <= wf_s2;
              d1_lat  <= wf_d1;

              -- output winners immediately
              s1_id_o <= wf_s1;
              s2_id_o <= wf_s2;

              st <= ST_EA_START;
            end if;

          when ST_EA_START =>
            if edge_busy='0' then
              edge_start <= '1';
              st <= ST_EA_WAIT;
            end if;

          when ST_EA_WAIT =>
            if edge_done='1' then
              -- request accumulate_error (applied by err_mem_proc)
              err_we  <= '1';
              err_wid <= s1_lat;
              err_add <= d1_lat;

              -- store to winner log AFTER edge aging
              win_mem(to_integer(step_idx)) <=
                std_logic_vector(s2_lat) &
                std_logic_vector(s1_lat);

              st <= ST_NEXT;
            end if;

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

  ---------------------------------------------------------------------------
  -- err_mem single-writer: init + accumulate
  ---------------------------------------------------------------------------
  process(clk_i)
    variable i       : integer;
    variable idxi    : integer;

    variable old_err : unsigned(30 downto 0);
    variable add_err : unsigned(30 downto 0);
    variable sum32   : unsigned(31 downto 0);
    variable new_err : unsigned(30 downto 0);
  begin
    if rising_edge(clk_i) then
      if (rstn_i='0') or (start_p='1') then
        -- clear all
        for i in 0 to MAX_NODES-1 loop
          err_mem(i) <= (others => '0');
        end loop;

        -- set active bits (debug: node0 & node1)
        if MAX_NODES > 0 then err_mem(0)(31) <= '1'; end if;
        if MAX_NODES > 1 then err_mem(1)(31) <= '1'; end if;

      else
        if err_we = '1' then
          idxi := to_integer(err_wid);

          if (idxi >= 0) and (idxi < integer(MAX_NODES)) then
            old_err := unsigned(err_mem(idxi)(30 downto 0));

            -- clamp add to 31-bit
            if err_add(32 downto 31) /= "00" then
              add_err := (others => '1');
            else
              add_err := resize(err_add(30 downto 0), 31);
            end if;

            sum32 := ('0' & old_err) + ('0' & add_err);

            if sum32(31) = '1' then
              new_err := (others => '1'); -- saturate
            else
              new_err := sum32(30 downto 0);
            end if;

            err_mem(idxi)(31)          <= '1'; -- keep/set active
            err_mem(idxi)(30 downto 0) <= std_logic_vector(new_err);
          end if;
        end if;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Debug taps: node + err (sync 1-cycle style)
  ---------------------------------------------------------------------------
  process(clk_i)
    variable a : integer;
  begin
    if rising_edge(clk_i) then
      -- node
      a := to_integer(dbg_node_raddr_i);
      if a = 0 then
        dbg_node_rdata_o <= pack_xy(INIT_X0, INIT_Y0);
      elsif a = 1 then
        dbg_node_rdata_o <= pack_xy(INIT_X1, INIT_Y1);
      else
        dbg_node_rdata_o <= (others => '0');
      end if;

      -- err
      a := to_integer(dbg_err_raddr_i);
      if (a >= 0) and (a < integer(MAX_NODES)) then
        dbg_err_rdata_o <= err_mem(a);
      else
        dbg_err_rdata_o <= (others => '0');
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- winner log tap (sync 1-cycle)
  ---------------------------------------------------------------------------
  process(clk_i)
    variable wa : integer;
  begin
    if rising_edge(clk_i) then
      wa := to_integer(dbg_win_raddr_i);
      if (wa >= 0) and (wa < integer(DATA_WORDS)) then
        dbg_win_rdata_o <= win_mem(wa);
      else
        dbg_win_rdata_o <= (others => '0');
      end if;
    end if;
  end process;

end architecture;
