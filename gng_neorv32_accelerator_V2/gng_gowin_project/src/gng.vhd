library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng is
  generic (
    MAX_NODES        : natural := 40;

    DATA_WORDS       : natural := 100;
    DONE_EVERY_STEPS : natural := 10; -- unused (debug-only)

    INIT_X0          : integer := 200;
    INIT_Y0          : integer := 200;
    INIT_X1          : integer := 800;
    INIT_Y1          : integer := 800;

    EDGE_A_MAX       : natural := 50;

    -- learning rates (shift-based)
    EPS_W_SHIFT      : natural := 3; -- winner 1/8
    EPS_N_SHIFT      : natural := 5  -- neighbor 1/32
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

  subtype u8_t  is unsigned(7 downto 0);
  subtype u13_t is unsigned(12 downto 0);
  subtype u33_t is unsigned(32 downto 0);
  subtype s16_t is signed(15 downto 0);

  ---------------------------------------------------------------------------
  -- FSM
  ---------------------------------------------------------------------------
  type st_t is (
    ST_IDLE,
    ST_RD_SET, ST_RD_WAIT, ST_RD_LATCH,
    ST_WF_START, ST_WF_WAIT,
    ST_EA_START, ST_EA_WAIT,
    ST_ERR_UPDATE,
    ST_MV_START, ST_MV_WAIT,
    ST_LOG,
    ST_NEXT, ST_FINISH
  );
  signal st : st_t := ST_IDLE;

  ---------------------------------------------------------------------------
  -- dataset
  ---------------------------------------------------------------------------
  signal step_idx : unsigned(6 downto 0) := (others => '0');
  signal x_s      : s16_t := (others => '0');
  signal y_s      : s16_t := (others => '0');

  -- start pulse
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  ---------------------------------------------------------------------------
  -- node set
  ---------------------------------------------------------------------------
  function init_active_mask return std_logic_vector is
    variable m : std_logic_vector(MAX_NODES-1 downto 0) := (others => '0');
  begin
    if MAX_NODES > 0 then m(0) := '1'; end if;
    if MAX_NODES > 1 then m(1) := '1'; end if;
    return m;
  end function;

  signal node_count  : u8_t := to_unsigned(2,8);
  signal active_mask : std_logic_vector(MAX_NODES-1 downto 0) := init_active_mask;

  ---------------------------------------------------------------------------
  -- Node "register file" (avoid BRAM inference issues)
  ---------------------------------------------------------------------------
  type node_mem_t is array (0 to MAX_NODES-1) of std_logic_vector(31 downto 0);
  signal node_mem : node_mem_t := (others => (others => '0'));

  -- shared sync read (1-cycle)
  signal node_raddr_mux : u8_t := (others => '0');
  signal node_rdata     : std_logic_vector(31 downto 0) := (others => '0');

  -- mux sources
  signal wf_node_raddr  : u8_t := (others => '0');
  signal mv_node_raddr  : u8_t := (others => '0');

  -- write from mover
  signal mv_node_we    : std_logic;
  signal mv_node_waddr : u8_t;
  signal mv_node_wdata : std_logic_vector(31 downto 0);

  function pack_xy(xi : integer; yi : integer) return std_logic_vector is
    variable x16 : s16_t;
    variable y16 : s16_t;
    variable w   : std_logic_vector(31 downto 0);
  begin
    x16 := to_signed(xi,16);
    y16 := to_signed(yi,16);
    w(15 downto 0)  := std_logic_vector(x16);
    w(31 downto 16) := std_logic_vector(y16);
    return w;
  end function;

  ---------------------------------------------------------------------------
  -- Winner finder (L2^2)
  ---------------------------------------------------------------------------
  signal wf_start : std_logic := '0';
  signal wf_done  : std_logic;
  signal wf_busy  : std_logic;
  signal wf_s1    : u8_t;
  signal wf_s2    : u8_t;
  signal wf_d1    : u33_t;

  -- latch winner outputs for later stages
  signal s1_lat : u8_t := (others => '0');
  signal s2_lat : u8_t := (others => '0');
  signal d1_lat : u33_t := (others => '0');

  ---------------------------------------------------------------------------
  -- Edge aging
  ---------------------------------------------------------------------------
  signal edge_start : std_logic := '0';
  signal edge_done  : std_logic;
  signal edge_busy  : std_logic;

  -- share edge debug read port with mover edge read
  signal mv_edge_raddr  : u13_t := (others => '0');
  signal edge_raddr_mux : u13_t := (others => '0');
  signal edge_word      : std_logic_vector(15 downto 0) := (others => '0');

  ---------------------------------------------------------------------------
  -- Error memory (bit31=active, bit30..0=err)
  ---------------------------------------------------------------------------
  type err_mem_t is array (0 to MAX_NODES-1) of std_logic_vector(31 downto 0);
  signal err_mem : err_mem_t := (others => (others => '0'));

  signal err_clr  : std_logic := '0';
  signal err_we   : std_logic := '0';
  signal err_wid  : u8_t := (others => '0');
  signal err_wdat : std_logic_vector(31 downto 0) := (others => '0');

  -- sync read out for debug
  signal err_rdata_dbg : std_logic_vector(31 downto 0) := (others => '0');

  -- helper: read current error word for id (combinational via loop)
  impure function err_read_word(id : u8_t) return std_logic_vector is
    variable r : std_logic_vector(31 downto 0) := (others => '0');
  begin
    for i in 0 to MAX_NODES-1 loop
      if id = to_unsigned(i, 8) then
        r := err_mem(i);
      end if;
    end loop;
    return r;
  end function;

  ---------------------------------------------------------------------------
  -- Winner log (store winners for 100 samples) as regs (avoid RAM inference)
  ---------------------------------------------------------------------------
  type win_mem_t is array (0 to DATA_WORDS-1) of std_logic_vector(15 downto 0);
  signal win_mem : win_mem_t := (others => (others => '0'));

  signal win_clr : std_logic := '0';
  signal win_we  : std_logic := '0';
  signal win_waddr : unsigned(6 downto 0) := (others => '0');
  signal win_wdata : std_logic_vector(15 downto 0) := (others => '0');

  signal win_rdata_dbg : std_logic_vector(15 downto 0) := (others => '0');

  ---------------------------------------------------------------------------
  -- Move winner+neighbors module
  ---------------------------------------------------------------------------
  signal mv_start : std_logic := '0';
  signal mv_busy  : std_logic;
  signal mv_done  : std_logic;

begin

  ---------------------------------------------------------------------------
  -- start edge detect
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
  -- dataset addr
  ---------------------------------------------------------------------------
  data_raddr_o <= step_idx;

  ---------------------------------------------------------------------------
  -- node_count & active_mask init on reset AND on start
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if (rstn_i='0') or (start_p='1') then
        active_mask <= init_active_mask;
        node_count  <= to_unsigned(2,8);
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Node memory:
  -- - init on reset/start
  -- - write via mv_node_we (decoder loop => regs)
  -- - sync read 1-cycle via mux loop => node_rdata
  ---------------------------------------------------------------------------
  process(clk_i)
    variable rd_next : std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk_i) then

      if (rstn_i='0') or (start_p='1') then
        for i in 0 to MAX_NODES-1 loop
          node_mem(i) <= (others => '0');
        end loop;
        if MAX_NODES > 0 then node_mem(0) <= pack_xy(INIT_X0, INIT_Y0); end if;
        if MAX_NODES > 1 then node_mem(1) <= pack_xy(INIT_X1, INIT_Y1); end if;

      else
        if mv_node_we = '1' then
          for i in 0 to MAX_NODES-1 loop
            if mv_node_waddr = to_unsigned(i,8) then
              node_mem(i) <= mv_node_wdata;
            end if;
          end loop;
        end if;
      end if;

      -- sync read (1-cycle): mux by loop
      rd_next := (others => '0');
      for i in 0 to MAX_NODES-1 loop
        if node_raddr_mux = to_unsigned(i,8) then
          rd_next := node_mem(i);
        end if;
      end loop;
      node_rdata <= rd_next;

    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Node read address MUX:
  -- idle => debug
  -- during winner-find => wf
  -- otherwise => mover
  ---------------------------------------------------------------------------
  node_raddr_mux <= dbg_node_raddr_i when (st = ST_IDLE) else
                    wf_node_raddr     when (wf_busy = '1') else
                    mv_node_raddr;

  dbg_node_rdata_o <= node_rdata;

  ---------------------------------------------------------------------------
  -- Winner finder instance (L2^2)
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
      node_rdata_i => node_rdata,

      s1_o => wf_s1,
      s2_o => wf_s2,
      d1_o => wf_d1
    );

  ---------------------------------------------------------------------------
  -- Edge aging instance:
  -- share dbg_edge address with mover edge read when mover busy
  ---------------------------------------------------------------------------
  edge_raddr_mux <= mv_edge_raddr when (mv_busy='1') else dbg_edge_raddr_i;

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

      dbg_edge_raddr_i => edge_raddr_mux,
      dbg_edge_rdata_o => edge_word
    );

  dbg_edge_rdata_o <= edge_word;

  ---------------------------------------------------------------------------
  -- Move winner + neighbors module
  ---------------------------------------------------------------------------
  u_move : entity work.gng_move_winner_neighbors
    generic map (
      MAX_NODES   => MAX_NODES,
      EPS_W_SHIFT => EPS_W_SHIFT,
      EPS_N_SHIFT => EPS_N_SHIFT
    )
    port map (
      clk_i  => clk_i,
      rstn_i => rstn_i,

      start_i => mv_start,
      busy_o  => mv_busy,
      done_o  => mv_done,

      x_i => x_s,
      y_i => y_s,

      s1_i         => s1_lat,
      node_count_i => node_count,

      node_raddr_o => mv_node_raddr,
      node_rdata_i => node_rdata,
      node_we_o    => mv_node_we,
      node_waddr_o => mv_node_waddr,
      node_wdata_o => mv_node_wdata,

      edge_raddr_o => mv_edge_raddr,
      edge_rdata_i => edge_word
    );

  ---------------------------------------------------------------------------
  -- Error memory: regs + single-writer
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if (rstn_i='0') or (err_clr='1') then
        for i in 0 to MAX_NODES-1 loop
          err_mem(i) <= (others => '0');
        end loop;
        if MAX_NODES > 0 then err_mem(0)(31) <= '1'; end if;
        if MAX_NODES > 1 then err_mem(1)(31) <= '1'; end if;

      elsif err_we='1' then
        for i in 0 to MAX_NODES-1 loop
          if err_wid = to_unsigned(i,8) then
            err_mem(i) <= err_wdat;
          end if;
        end loop;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Error debug read (sync 1-cycle)
  ---------------------------------------------------------------------------
  process(clk_i)
    variable rd_next : std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk_i) then
      rd_next := (others => '0');
      for i in 0 to MAX_NODES-1 loop
        if dbg_err_raddr_i = to_unsigned(i,8) then
          rd_next := err_mem(i);
        end if;
      end loop;
      err_rdata_dbg <= rd_next;
    end if;
  end process;

  dbg_err_rdata_o <= err_rdata_dbg;

  ---------------------------------------------------------------------------
  -- Winner log regs
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if (rstn_i='0') or (win_clr='1') then
        for i in 0 to DATA_WORDS-1 loop
          win_mem(i) <= (others => '0');
        end loop;

      elsif win_we='1' then
        for i in 0 to DATA_WORDS-1 loop
          if win_waddr = to_unsigned(i,7) then
            win_mem(i) <= win_wdata;
          end if;
        end loop;
      end if;
    end if;
  end process;

  -- win debug read (sync 1-cycle)
  process(clk_i)
    variable rd_next : std_logic_vector(15 downto 0);
  begin
    if rising_edge(clk_i) then
      rd_next := (others => '0');
      for i in 0 to DATA_WORDS-1 loop
        if dbg_win_raddr_i = to_unsigned(i,7) then
          rd_next := win_mem(i);
        end if;
      end loop;
      win_rdata_dbg <= rd_next;
    end if;
  end process;

  dbg_win_rdata_o <= win_rdata_dbg;

  ---------------------------------------------------------------------------
  -- Main FSM
  ---------------------------------------------------------------------------
  process(clk_i)
    variable s1w       : std_logic_vector(31 downto 0);
    variable s1i       : integer;

    variable old_err   : unsigned(30 downto 0);
    variable add_err   : unsigned(30 downto 0);
    variable sum32     : unsigned(31 downto 0);
    variable new_err   : unsigned(30 downto 0);
  begin
    if rising_edge(clk_i) then
      -- defaults
      wf_start   <= '0';
      edge_start <= '0';
      mv_start   <= '0';

      gng_done_o <= '0';

      err_clr  <= '0';
      err_we   <= '0';
      err_wid  <= (others => '0');
      err_wdat <= (others => '0');

      win_clr   <= '0';
      win_we    <= '0';
      win_waddr <= (others => '0');
      win_wdata <= (others => '0');

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

      else
        case st is

          when ST_IDLE =>
            if start_p='1' then
              err_clr <= '1';
              win_clr <= '1';
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
              s1_lat <= wf_s1;
              s2_lat <= wf_s2;
              d1_lat <= wf_d1;

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
              st <= ST_ERR_UPDATE;
            end if;

          when ST_ERR_UPDATE =>
            -- err[s1] += d1 (L2^2), saturate to 31-bit
            s1i := to_integer(s1_lat);
            if (s1i >= 0) and (s1i < integer(MAX_NODES)) then
              s1w := err_read_word(s1_lat);
              old_err := unsigned(s1w(30 downto 0));

              -- clamp add to 31-bit
              if d1_lat(32 downto 31) /= "00" then
                add_err := (others => '1');
              else
                add_err := resize(unsigned(d1_lat(30 downto 0)), 31);
              end if;

              sum32 := ('0' & old_err) + ('0' & add_err);

              if sum32(31)='1' then
                new_err := (others => '1');
              else
                new_err := sum32(30 downto 0);
              end if;

              err_we  <= '1';
              err_wid <= s1_lat;
              err_wdat <= '1' & std_logic_vector(new_err); -- keep active=1
            end if;

            st <= ST_MV_START;

          when ST_MV_START =>
            if mv_busy='0' then
              mv_start <= '1';
              st <= ST_MV_WAIT;
            end if;

          when ST_MV_WAIT =>
            if mv_done='1' then
              st <= ST_LOG;
            end if;

          when ST_LOG =>
            -- store: [7:0]=s1, [15:8]=s2
            win_we    <= '1';
            win_waddr <= step_idx;
            win_wdata <= std_logic_vector(s2_lat) & std_logic_vector(s1_lat);
            st <= ST_NEXT;

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

end architecture;
