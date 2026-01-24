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
  -- Dataset BRAM C settings
  ---------------------------------------------------------------------------
  constant DEPTH_BYTES : natural := 400;
  constant WORDS_C     : natural := DEPTH_BYTES/4; -- 100

  ---------------------------------------------------------------------------
  -- GNG sizing
  ---------------------------------------------------------------------------
  constant GNG_MAX_NODES : natural := 40;
  constant GNG_MAX_DEG   : natural := 6;

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
  -- BRAM_C (word32)
  ---------------------------------------------------------------------------
  type mem_c_t is array (0 to WORDS_C-1) of std_logic_vector(31 downto 0);
  signal mem_c : mem_c_t;

  -- write from copy
  signal c_we_copy    : std_logic;
  signal c_waddr_copy : unsigned(6 downto 0);
  signal c_wdata_copy : std_logic_vector(31 downto 0);

  -- write from shift
  signal c_we_shift    : std_logic;
  signal c_waddr_shift : unsigned(6 downto 0);
  signal c_wdata_shift : std_logic_vector(31 downto 0);

  -- merged write (shift wins over copy)
  signal c_we_mem    : std_logic;
  signal c_waddr_mem : unsigned(6 downto 0);
  signal c_wdata_mem : std_logic_vector(31 downto 0);

  -- read addresses (SEPARATE)
  signal c_raddr_shift : unsigned(6 downto 0) := (others => '0');
  signal c_raddr_gng   : unsigned(6 downto 0) := (others => '0');

  -- read datas (SEPARATE)
  signal c_rdata_shift : std_logic_vector(31 downto 0) := (others => '0');
  signal c_rdata_gng   : std_logic_vector(31 downto 0) := (others => '0');

  ---------------------------------------------------------------------------
  -- copy flags
  ---------------------------------------------------------------------------
  signal copying   : std_logic;
  signal copy_done : std_logic;

  ---------------------------------------------------------------------------
  -- shift flags
  ---------------------------------------------------------------------------
  signal shifting      : std_logic;
  signal shift_done    : std_logic;
  signal shift_start_p : std_logic := '0';

  ---------------------------------------------------------------------------
  -- GNG flags
  ---------------------------------------------------------------------------
  signal gng_start_p : std_logic := '0';
  signal gng_done_p  : std_logic;
  signal gng_busy    : std_logic;

  ---------------------------------------------------------------------------
  -- debug latches
  ---------------------------------------------------------------------------
  signal full_rx_store : std_logic := '0';
  signal data_ready_p  : std_logic := '0';

  ---------------------------------------------------------------------------
  -- Scheduler
  ---------------------------------------------------------------------------
  constant SHIFT_EVERY_PKTS : natural := 5;

  type sm_t is (WAIT_DATA, RUN_GNG, WAIT_GNG, DO_DUMP, WAIT_DUMP, DO_SHIFT, WAIT_SHIFT);
  signal sm : sm_t := WAIT_DATA;

  signal pkt_cnt_shift : unsigned(7 downto 0) := (others => '0');

  ---------------------------------------------------------------------------
  -- GNG dump read taps (from GNG debug ports)
  ---------------------------------------------------------------------------
  signal dump_node_raddr : unsigned(5 downto 0) := (others => '0');
  signal dump_node_rdata : std_logic_vector(31 downto 0);

  signal dump_err_raddr  : unsigned(5 downto 0) := (others => '0');
  signal dump_err_rdata  : std_logic_vector(31 downto 0);

  signal dump_edge_raddr : unsigned(8 downto 0) := (others => '0');
  signal dump_edge_rdata : std_logic_vector(15 downto 0);

  ---------------------------------------------------------------------------
  -- Dump control (one-shot)
  ---------------------------------------------------------------------------
  signal dump_start_p : std_logic := '0';
  signal sending     : std_logic;
  signal send_done_p : std_logic;

begin

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
  -- BRAM_C write mux (shift wins over copy)
  ---------------------------------------------------------------------------
  c_we_mem    <= c_we_shift or c_we_copy;
  c_waddr_mem <= c_waddr_shift when (c_we_shift = '1') else c_waddr_copy;
  c_wdata_mem <= c_wdata_shift when (c_we_shift = '1') else c_wdata_copy;

  ---------------------------------------------------------------------------
  -- BRAM_C (sync write + MULTI sync read)
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if c_we_mem = '1' then
        mem_c(to_integer(c_waddr_mem)) <= c_wdata_mem;
      end if;

      -- 2 read taps (gng + shift)
      c_rdata_gng   <= mem_c(to_integer(c_raddr_gng));
      c_rdata_shift <= mem_c(to_integer(c_raddr_shift));
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
  -- data_ready latch
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        data_ready_p <= '0';
      elsif copy_done = '1' then
        data_ready_p <= '1';
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Scheduler: 1x GNG -> 1x DUMP -> repeat (shift tiap SHIFT_EVERY_PKTS)
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        sm <= WAIT_DATA;
        pkt_cnt_shift <= (others => '0');

        gng_start_p   <= '0';
        shift_start_p <= '0';
        dump_start_p  <= '0';

      else
        gng_start_p   <= '0';
        shift_start_p <= '0';
        dump_start_p  <= '0';

        case sm is
          when WAIT_DATA =>
            pkt_cnt_shift <= (others => '0');
            if data_ready_p = '1' then
              sm <= RUN_GNG;
            end if;

          when RUN_GNG =>
            -- optional safety: hanya start kalau engine idle
            if gng_busy = '0' then
              gng_start_p <= '1';
              sm <= WAIT_GNG;
            end if;

          when WAIT_GNG =>
            if gng_done_p = '1' then
              sm <= DO_DUMP;
            end if;

          when DO_DUMP =>
            -- start dump hanya saat aman (tidak sedang copy/shift) dan dumper idle
            if (copying = '0') and (shifting = '0') and (sending = '0') then
              dump_start_p <= '1';   -- pulse 1 clk
              sm <= WAIT_DUMP;
            end if;

          when WAIT_DUMP =>
            if send_done_p = '1' then
              -- 1 dump selesai = 1 siklus
              if pkt_cnt_shift = to_unsigned(SHIFT_EVERY_PKTS-1, pkt_cnt_shift'length) then
                pkt_cnt_shift <= (others => '0');
                sm <= DO_SHIFT;
              else
                pkt_cnt_shift <= pkt_cnt_shift + 1;
                sm <= RUN_GNG;       -- <--- kunci: langsung GNG lagi
              end if;
            end if;

          when DO_SHIFT =>
            shift_start_p <= '1';
            sm <= WAIT_SHIFT;

          when WAIT_SHIFT =>
            if shift_done = '1' then
              sm <= RUN_GNG;
            end if;

          when others =>
            sm <= WAIT_DATA;
        end case;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- GNG (reads dataset from mem_c)
  ---------------------------------------------------------------------------
  u_gng : entity work.gng
    generic map (
      MAX_NODES        => GNG_MAX_NODES,
      DATA_WORDS       => WORDS_C,
      DONE_EVERY_STEPS => 10,
      INIT_X0          => 200, INIT_Y0 => 200,
      INIT_X1          => 800, INIT_Y1 => 800
    )
    port map (
      clk_i   => clk_i,
      rstn_i  => rstn_i,
      start_i => gng_start_p,

      data_raddr_o => c_raddr_gng,
      data_rdata_i => c_rdata_gng,

      gng_done_o => gng_done_p,
      gng_busy_o => gng_busy,

      s1_id_o => open,
      s2_id_o => open,

      -- debug taps (HARUS ADA di entity gng)
      dbg_node_raddr_i => dump_node_raddr,
      dbg_node_rdata_o => dump_node_rdata,

      dbg_err_raddr_i  => dump_err_raddr,
      dbg_err_rdata_o  => dump_err_rdata,

      dbg_edge_raddr_i => dump_edge_raddr,
      dbg_edge_rdata_o => dump_edge_rdata
    );

  ---------------------------------------------------------------------------
  -- SHIFT word32 (update mem_c in-place)
  ---------------------------------------------------------------------------
  u_shift : entity work.bram_shift_word32_xy16
    generic map (
      WORDS   => WORDS_C,
      STEP_X  => 10,
      STEP_Y  => 0,
      LIMIT_X => 300,
      LIMIT_Y => 0
    )
    port map (
      clk_i   => clk_i,
      rstn_i  => rstn_i,
      start_i => shift_start_p,

      c_raddr_o => c_raddr_shift,
      c_rdata_i => c_rdata_shift,

      c_we_o    => c_we_shift,
      c_waddr_o => c_waddr_shift,
      c_wdata_o => c_wdata_shift,

      done_o => shift_done,
      busy_o => shifting
    );

  ---------------------------------------------------------------------------
  -- GNG DUMP SENDER (UART) - ONE SHOT
  ---------------------------------------------------------------------------
  u_dump_gng : entity work.gng_dump_state_uart_sumchk
    generic map (
      MAX_NODES => GNG_MAX_NODES,
      MAX_DEG   => GNG_MAX_DEG
    )
    port map (
      clk_i  => clk_i,
      rstn_i => rstn_i,

      start_i => dump_start_p,

      node_raddr_o => dump_node_raddr,
      node_rdata_i => dump_node_rdata,

      err_raddr_o  => dump_err_raddr,
      err_rdata_i  => dump_err_rdata,

      edge_raddr_o => dump_edge_raddr,
      edge_rdata_i => dump_edge_rdata,

      tx_busy_i    => tx_busy,
      tx_done_i    => tx_done,
      tx_start_o   => tx_start,
      tx_data_o    => tx_data,

      done_o       => send_done_p,
      busy_o       => sending
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
    5      => std_ulogic(not shifting),
    others => '1'
  );

end architecture;
