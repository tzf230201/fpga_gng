library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tang_nano_9k is
  generic (
    CLOCK_FREQUENCY : natural := 27_000_000;
    BAUD            : natural := 1_000_000;
    IO_GPIO_NUM     : natural := 6
  );
  port (
    clk_i      : in  std_logic;
    rstn_i     : in  std_logic;
    gpio_o     : out std_ulogic_vector(IO_GPIO_NUM-1 downto 0);
    uart_txd_o : out std_ulogic;
    uart_rxd_i : in  std_ulogic := '0'
  );
end entity;

architecture rtl of tang_nano_9k is

  ---------------------------------------------------------------------------
  -- Dataset BRAM settings
  ---------------------------------------------------------------------------
  constant DEPTH_BYTES : natural := 400;
  constant WORDS_C     : natural := DEPTH_BYTES/4; -- 100

  constant GNG_MAX_NODES : natural := 40; -- (ubah ke 100 nanti kalau mau)

  ---------------------------------------------------------------------------
  -- UART RX
  ---------------------------------------------------------------------------
  signal rx_data  : std_logic_vector(7 downto 0);
  signal rx_valid : std_logic;
  signal rx_busy  : std_logic;
  signal rx_err   : std_logic;

  ---------------------------------------------------------------------------
  -- UART TX
  ---------------------------------------------------------------------------
  signal tx_start : std_logic := '0';
  signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_busy  : std_logic;
  signal tx_done  : std_logic;
  signal txd      : std_logic;

  ---------------------------------------------------------------------------
  -- BRAM_A (RX store 8-bit)
  ---------------------------------------------------------------------------
  type mem_a_t is array (0 to DEPTH_BYTES-1) of std_logic_vector(7 downto 0);
  signal mem_a : mem_a_t;

  signal a_we    : std_logic;
  signal a_waddr : unsigned(8 downto 0);
  signal a_wdata : std_logic_vector(7 downto 0);

  signal a_raddr : unsigned(8 downto 0) := (others => '0');
  signal a_rdata : std_logic_vector(7 downto 0);

  signal full_p     : std_logic;
  signal locked     : std_logic;
  signal full_p_dly : std_logic := '0';

  ---------------------------------------------------------------------------
  -- BRAM_C (word32 dataset)
  ---------------------------------------------------------------------------
  type mem_c_t is array (0 to WORDS_C-1) of std_logic_vector(31 downto 0);
  signal mem_c : mem_c_t;

  -- write from copy
  signal c_we_copy    : std_logic;
  signal c_waddr_copy : unsigned(6 downto 0);
  signal c_wdata_copy : std_logic_vector(31 downto 0);

  -- read for gng
  signal c_raddr_gng : unsigned(6 downto 0) := (others => '0');
  signal c_rdata_gng : std_logic_vector(31 downto 0) := (others => '0');

  ---------------------------------------------------------------------------
  -- copy flags
  ---------------------------------------------------------------------------
  signal copying   : std_logic;
  signal copy_done : std_logic;

  signal have_data : std_logic := '0';

  ---------------------------------------------------------------------------
  -- GNG control
  ---------------------------------------------------------------------------
  signal gng_start_p : std_logic := '0';
  signal gng_done_p  : std_logic;
  signal gng_busy    : std_logic;

  ---------------------------------------------------------------------------
  -- GNG debug taps (read by dumper)  <-- UPDATED to 8-bit for node/err
  ---------------------------------------------------------------------------
  signal dump_node_raddr : unsigned(7 downto 0) := (others => '0');
  signal dump_node_rdata : std_logic_vector(31 downto 0);

  signal dump_err_raddr  : unsigned(7 downto 0) := (others => '0');
  signal dump_err_rdata  : std_logic_vector(31 downto 0);

  -- (not used) keep as-is
  signal dump_edge_raddr : unsigned(12 downto 0) := (others => '0');
  signal dump_edge_rdata : std_logic_vector(15 downto 0);

  signal dump_win_raddr  : unsigned(6 downto 0) := (others => '0');
  signal dump_win_rdata  : std_logic_vector(15 downto 0);

  ---------------------------------------------------------------------------
  -- DUMP control
  ---------------------------------------------------------------------------
  signal dump_start_p : std_logic := '0';
  signal sending      : std_logic;
  signal send_done_p  : std_logic;

  ---------------------------------------------------------------------------
  -- simple scheduler
  ---------------------------------------------------------------------------
  type sm_t is (WAIT_DATA, RUN_GNG, WAIT_GNG, DO_DUMP, WAIT_DUMP);
  signal sm : sm_t := WAIT_DATA;

  -- debug latch
  signal full_rx_store : std_logic := '0';

  -- step field for dumper (kalau perlu)
  signal step_zero : unsigned(15 downto 0) := (others => '0');

begin

  -- tie off edge raddr (dumper kamu tidak pakai edges)
  dump_edge_raddr <= (others => '0');

  ---------------------------------------------------------------------------
  -- Debug latch: remember full
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        full_rx_store <= '0';
      elsif full_p = '1' then
        full_rx_store <= '1';
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- full_p delayed 1 cycle
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        full_p_dly <= '0';
      else
        full_p_dly <= full_p;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- BRAM_A (sync write + sync read)
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if a_we = '1' then
        mem_a(to_integer(a_waddr)) <= a_wdata;
      end if;
      a_rdata <= mem_a(to_integer(a_raddr));
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- BRAM_C (sync write + sync read)
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if c_we_copy = '1' then
        mem_c(to_integer(c_waddr_copy)) <= c_wdata_copy;
      end if;
      c_rdata_gng <= mem_c(to_integer(c_raddr_gng));
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- UART RX
  ---------------------------------------------------------------------------
  u_rx : entity work.uart_rx
    generic map (
      CLOCK_FREQUENCY => CLOCK_FREQUENCY,
      BAUD            => BAUD
    )
    port map (
      clk_i   => clk_i,
      rstn_i  => rstn_i,
      rxd_i   => std_logic(uart_rxd_i),
      data_o  => rx_data,
      valid_o => rx_valid,
      busy_o  => rx_busy,
      err_o   => rx_err
    );

  ---------------------------------------------------------------------------
  -- RX STORE
  ---------------------------------------------------------------------------
  u_store : entity work.rx_store_ext
    generic map ( DEPTH => DEPTH_BYTES )
    port map (
      clk_i        => clk_i,
      rstn_i       => rstn_i,
      rx_valid_i   => rx_valid,
      rx_data_i    => rx_data,
      hold_i       => copying,
      clear_i      => '0',
      full_o       => full_p,

      mem_we_o     => a_we,
      mem_waddr_o  => a_waddr,
      mem_wdata_o  => a_wdata,

      mem_raddr_i  => a_raddr,
      mem_rdata_i  => a_rdata,

      rdata_o      => open,
      locked_o     => locked
    );

  ---------------------------------------------------------------------------
  -- COPY 8->32 (A -> C)
  ---------------------------------------------------------------------------
  u_copy_8to32 : entity work.bram_copy_8to32
    generic map ( DEPTH_BYTES => DEPTH_BYTES )
    port map (
      clk_i     => clk_i,
      rstn_i    => rstn_i,
      start_i   => full_p_dly,

      a_raddr_o => a_raddr,
      a_rdata_i => a_rdata,

      c_we_o    => c_we_copy,
      c_waddr_o => c_waddr_copy,
      c_wdata_o => c_wdata_copy,

      done_o    => copy_done,
      busy_o    => copying
    );

  ---------------------------------------------------------------------------
  -- have_data latch (set when copy_done pulse)
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i='0' then
        have_data <= '0';
      else
        if copy_done='1' then
          have_data <= '1';
        end if;
        -- clear when we actually start GNG
        if gng_start_p='1' then
          have_data <= '0';
        end if;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Scheduler: upload -> run gng debug -> dump
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i='0' then
        sm <= WAIT_DATA;
        gng_start_p  <= '0';
        dump_start_p <= '0';
      else
        gng_start_p  <= '0';
        dump_start_p <= '0';

        case sm is
          when WAIT_DATA =>
            if have_data='1' then
              sm <= RUN_GNG;
            end if;

          when RUN_GNG =>
            if gng_busy='0' then
              gng_start_p <= '1';
              sm <= WAIT_GNG;
            end if;

          when WAIT_GNG =>
            if gng_done_p='1' then
              sm <= DO_DUMP;
            end if;

          when DO_DUMP =>
            if sending='0' then
              dump_start_p <= '1';
              sm <= WAIT_DUMP;
            end if;

          when WAIT_DUMP =>
            if send_done_p='1' then
              sm <= WAIT_DATA;
            end if;

          when others =>
            sm <= WAIT_DATA;
        end case;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- GNG DEBUG winner-only (reads dataset from mem_c)
  -- NOTE: entity work.gng kamu harus sudah versi 8-bit untuk dbg_node/err addr
  ---------------------------------------------------------------------------
  u_gng : entity work.gng
    generic map (
      MAX_NODES  => GNG_MAX_NODES,
      DATA_WORDS => WORDS_C,
      INIT_X0    => 200, INIT_Y0 => 200,
      INIT_X1    => 800, INIT_Y1 => 800
    )
    port map (
      clk_i   => clk_i,
      rstn_i  => rstn_i,
      start_i => gng_start_p,

      data_raddr_o => c_raddr_gng,
      data_rdata_i => c_rdata_gng,

      gng_done_o => gng_done_p,
      gng_busy_o => gng_busy,

      s1_id_o => open, -- 8-bit IDs (boleh open)
      s2_id_o => open,

      dbg_node_raddr_i => dump_node_raddr,
      dbg_node_rdata_o => dump_node_rdata,

      dbg_err_raddr_i  => dump_err_raddr,
      dbg_err_rdata_o  => dump_err_rdata,

      dbg_edge_raddr_i => dump_edge_raddr,
      dbg_edge_rdata_o => dump_edge_rdata,

      dbg_win_raddr_i  => dump_win_raddr,
      dbg_win_rdata_o  => dump_win_rdata
    );

  ---------------------------------------------------------------------------
  -- DUMP (0xA1 then 0xB1)
  -- NOTE: entity work.gng_dump_nodes_winners_uart harus sudah 8-bit node/err addr
  ---------------------------------------------------------------------------
  u_dump : entity work.gng_dump_nodes_winners_uart
    generic map (
      MAX_NODES  => GNG_MAX_NODES,
      MASK_BYTES => 8,       -- untuk 40 nodes OK. kalau 100 nodes => set 13
      N_SAMPLES  => WORDS_C
    )
    port map (
      clk_i   => clk_i,
      rstn_i  => rstn_i,
      start_i => dump_start_p,

      node_raddr_o => dump_node_raddr,
      node_rdata_i => dump_node_rdata,

      err_raddr_o  => dump_err_raddr,
      err_rdata_i  => dump_err_rdata,

      win_raddr_o  => dump_win_raddr,
      win_rdata_i  => dump_win_rdata,

      step_i => step_zero,

      tx_busy_i  => tx_busy,
      tx_done_i  => tx_done,
      tx_start_o => tx_start,
      tx_data_o  => tx_data,

      done_o => send_done_p,
      busy_o => sending
    );

  ---------------------------------------------------------------------------
  -- UART TX
  ---------------------------------------------------------------------------
  u_tx : entity work.uart_tx
    generic map (
      CLOCK_FREQUENCY => CLOCK_FREQUENCY,
      BAUD            => BAUD
    )
    port map (
      clk_i   => clk_i,
      rstn_i  => rstn_i,
      start_i => tx_start,
      data_i  => tx_data,
      txd_o   => txd,
      busy_o  => tx_busy,
      done_o  => tx_done
    );

  uart_txd_o <= std_ulogic(txd);

  ---------------------------------------------------------------------------
  -- LEDs active-low
  ---------------------------------------------------------------------------
  gpio_o <= (
    0      => std_ulogic(not sending),
    1      => std_ulogic(not copying),
    2      => std_ulogic(not locked),
    3      => std_ulogic(not full_rx_store),
    4      => std_ulogic(not gng_busy),
    5      => '1',
    others => '1'
  );

end architecture;
