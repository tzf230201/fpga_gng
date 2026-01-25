library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng is
  generic (
    MAX_NODES        : natural := 40;
    MAX_DEG          : natural := 6;

    DATA_WORDS       : natural := 100;
    DONE_EVERY_STEPS : natural := 10; -- (unused in this debug-only version)

    INIT_X0          : integer := 200;
    INIT_Y0          : integer := 200;
    INIT_X1          : integer := 800;
    INIT_Y1          : integer := 800
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

    s1_id_o : out unsigned(5 downto 0);
    s2_id_o : out unsigned(5 downto 0);

    -- debug taps for 0xA1 dumper
    dbg_node_raddr_i : in  unsigned(5 downto 0);
    dbg_node_rdata_o : out std_logic_vector(31 downto 0);

    dbg_err_raddr_i  : in  unsigned(5 downto 0);
    dbg_err_rdata_o  : out std_logic_vector(31 downto 0);

    dbg_edge_raddr_i : in  unsigned(8 downto 0);
    dbg_edge_rdata_o : out std_logic_vector(15 downto 0);

    -- winner-log tap for 0xB1 dumper
    dbg_win_raddr_i  : in  unsigned(6 downto 0);           -- 0..99
    dbg_win_rdata_o  : out std_logic_vector(15 downto 0)   -- [7:0]=s1 [15:8]=s2
  );
end entity;

architecture rtl of gng is

  -- FIX: jangan pakai literal "NEXT" (reserved word VHDL)
  type st_t is (ST_IDLE, ST_RD_SET, ST_RD_WAIT, ST_RD_LATCH, ST_WF_START, ST_WF_WAIT, ST_NEXT, ST_FINISH);
  signal st : st_t := ST_IDLE;

  signal step_idx : unsigned(6 downto 0) := (others => '0');
  signal x_s      : signed(15 downto 0) := (others => '0');
  signal y_s      : signed(15 downto 0) := (others => '0');

  -- start edge detect
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  -- winner finder signals
  signal wf_start : std_logic := '0';
  signal wf_done  : std_logic;
  signal wf_busy  : std_logic;
  signal wf_s1    : unsigned(5 downto 0);
  signal wf_s2    : unsigned(5 downto 0);
  signal wf_d1    : unsigned(16 downto 0);

  -- node scan interface
  signal wf_node_raddr : unsigned(5 downto 0) := (others => '0');
  signal wf_node_rdata : std_logic_vector(31 downto 0) := (others => '0');

  signal node_count  : unsigned(5 downto 0) := to_unsigned(2,6);
  signal active_mask : std_logic_vector(MAX_NODES-1 downto 0) := (others => '0');

  -- winner log BRAM (100 records)
  type win_mem_t is array (0 to DATA_WORDS-1) of std_logic_vector(15 downto 0);
  signal win_mem : win_mem_t := (others => (others => '0'));

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

  -- start pulse
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

  -- only node0 & node1 active (debug version)
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i='0' then
        active_mask <= (others => '0');
        if MAX_NODES > 0 then active_mask(0) <= '1'; end if;
        if MAX_NODES > 1 then active_mask(1) <= '1'; end if;
        node_count  <= to_unsigned(2,6);
      end if;
    end if;
  end process;

  -- dataset addr (sync BRAM outside)
  data_raddr_o <= step_idx;

  -- winner finder node "ROM" (sync 1-cycle read)
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

  -- instantiate winner finder
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

  -- main FSM
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      wf_start   <= '0';
      gng_done_o <= '0';

      if rstn_i='0' then
        st       <= ST_IDLE;
        step_idx <= (others => '0');
        x_s      <= (others => '0');
        y_s      <= (others => '0');
        s1_id_o  <= (others => '0');
        s2_id_o  <= (others => '0');

      else
        case st is

          when ST_IDLE =>
            if start_p='1' then
              step_idx <= (others => '0');
              st <= ST_RD_SET;
            end if;

          when ST_RD_SET =>
            -- address already stable via step_idx
            st <= ST_RD_WAIT;

          when ST_RD_WAIT =>
            -- wait 1 cycle for data_rdata_i
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
              s1_id_o <= wf_s1;
              s2_id_o <= wf_s2;

              -- store to winner log: [7:0]=s1, [15:8]=s2
              win_mem(to_integer(step_idx)) <=
                std_logic_vector(resize(wf_s2, 8)) &
                std_logic_vector(resize(wf_s1, 8));

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
  -- Debug taps (0xA1): nodes/err/edge
  ---------------------------------------------------------------------------
  process(clk_i)
    variable a : integer;
  begin
    if rising_edge(clk_i) then
      a := to_integer(dbg_node_raddr_i);
      if a = 0 then
        dbg_node_rdata_o <= pack_xy(INIT_X0, INIT_Y0);
      elsif a = 1 then
        dbg_node_rdata_o <= pack_xy(INIT_X1, INIT_Y1);
      else
        dbg_node_rdata_o <= (others => '0');
      end if;

      dbg_err_rdata_o  <= (others => '0');
      dbg_edge_rdata_o <= (others => '0');
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Debug tap (0xB1) winner log: sync 1-cycle read
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
