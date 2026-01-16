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
  constant DEPTH : natural := 400;

  -----------------------------------------------------------------------------
  -- UART RX
  -----------------------------------------------------------------------------
  signal rx_data  : std_logic_vector(7 downto 0);
  signal rx_valid : std_logic;
  signal rx_busy  : std_logic;
  signal rx_err   : std_logic;

  -----------------------------------------------------------------------------
  -- UART TX
  -----------------------------------------------------------------------------
  signal tx_start : std_logic;
  signal tx_data  : std_logic_vector(7 downto 0);
  signal tx_busy  : std_logic;
  signal tx_done  : std_logic;
  signal txd      : std_logic;

  -----------------------------------------------------------------------------
  -- BRAM_A (RX store)
  -----------------------------------------------------------------------------
  type mem_a_t is array (0 to DEPTH-1) of std_logic_vector(7 downto 0);
  signal mem_a : mem_a_t;

  signal a_we    : std_logic;
  signal a_waddr : unsigned(8 downto 0);
  signal a_wdata : std_logic_vector(7 downto 0);

  signal a_raddr : unsigned(8 downto 0);
  signal a_rdata : std_logic_vector(7 downto 0);

  -- RX store control
  signal full_p     : std_logic;
  signal locked     : std_logic;
  signal full_p_dly : std_logic := '0';

  -----------------------------------------------------------------------------
  -- BRAM_B (stream buffer)
  -----------------------------------------------------------------------------
  type mem_b_t is array (0 to DEPTH-1) of std_logic_vector(7 downto 0);
  signal mem_b : mem_b_t;

  -- BRAM_B read mux (decay vs sender)
  signal b_raddr_mem  : unsigned(8 downto 0);
  signal b_rdata      : std_logic_vector(7 downto 0);
  signal b_raddr_send : unsigned(8 downto 0);
  signal b_raddr_dec  : unsigned(8 downto 0);

  -- BRAM_B write mux (decay wins over copy)
  signal b_we_mem     : std_logic;
  signal b_waddr_mem  : unsigned(8 downto 0);
  signal b_wdata_mem  : std_logic_vector(7 downto 0);

  signal b_we_copy    : std_logic;
  signal b_waddr_copy : unsigned(8 downto 0);
  signal b_wdata_copy : std_logic_vector(7 downto 0);

  signal b_we_dec     : std_logic;
  signal b_waddr_dec  : unsigned(8 downto 0);
  signal b_wdata_dec  : std_logic_vector(7 downto 0);

  -----------------------------------------------------------------------------
  -- copy / send / decay flags
  -----------------------------------------------------------------------------
  signal copying   : std_logic;
  signal copy_done : std_logic;

  signal sending     : std_logic;
  signal send_done_p : std_logic;

  signal decaying   : std_logic;
  signal decay_done : std_logic;

  -----------------------------------------------------------------------------
  -- debug latches
  -----------------------------------------------------------------------------
  signal full_rx_store : std_logic := '0';
  signal data_ready_p  : std_logic := '0';

  -----------------------------------------------------------------------------
  -- Scheduler: decay each N packets
  -----------------------------------------------------------------------------
  constant DECAY_EVERY_PKTS : natural := 5; -- DEBUG: kecil biar sering decay (ubah bebas)

  type sm_t is (WAIT_DATA, STREAMING, DO_DECAY, WAIT_DECAY);
  signal sm : sm_t := WAIT_DATA;

  signal pkt_cnt           : unsigned(7 downto 0) := (others => '0');
  signal decay_start_pulse : std_logic := '0';

  -- pause sender during copy/decay/scheduling
  signal pause_send : std_logic;
  signal pause_sm   : std_logic; -- FIX: convert boolean (sm=...) to std_logic

begin

  -----------------------------------------------------------------------------
  -- Debug latch: remember full
  -----------------------------------------------------------------------------
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

  -----------------------------------------------------------------------------
  -- full_p delayed 1 cycle
  -----------------------------------------------------------------------------
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

  -----------------------------------------------------------------------------
  -- BRAM_A (sync write + sync read)
  -----------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if a_we = '1' then
        mem_a(to_integer(a_waddr)) <= a_wdata;
      end if;
      a_rdata <= mem_a(to_integer(a_raddr));
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- BRAM_B muxes
  -- Read: decay when decaying else sender
  -----------------------------------------------------------------------------
  b_raddr_mem <= b_raddr_dec when (decaying = '1') else b_raddr_send;

  -- Write: decay wins over copy
  b_we_mem    <= b_we_dec or b_we_copy;
  b_waddr_mem <= b_waddr_dec when (b_we_dec = '1') else b_waddr_copy;
  b_wdata_mem <= b_wdata_dec when (b_we_dec = '1') else b_wdata_copy;

  -----------------------------------------------------------------------------
  -- BRAM_B (sync write + sync read)
  -----------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if b_we_mem = '1' then
        mem_b(to_integer(b_waddr_mem)) <= b_wdata_mem;
      end if;
      b_rdata <= mem_b(to_integer(b_raddr_mem));
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- UART RX
  -----------------------------------------------------------------------------
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

  -----------------------------------------------------------------------------
  -- RX STORE (lock after full)
  -----------------------------------------------------------------------------
  u_store : entity work.rx_store_ext
    generic map ( DEPTH => DEPTH )
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

  -----------------------------------------------------------------------------
  -- COPY (A -> B)
  -----------------------------------------------------------------------------
  u_copy : entity work.bram_copy
    generic map ( DEPTH => DEPTH )
    port map (
      clk_i     => clk_i,
      rstn_i    => rstn_i,
      start_i   => full_p_dly,

      a_raddr_o => a_raddr,
      a_rdata_i => a_rdata,

      b_waddr_o => b_waddr_copy,
      b_wdata_o => b_wdata_copy,
      b_we_o    => b_we_copy,

      done_o    => copy_done,
      busy_o    => copying
    );

  -----------------------------------------------------------------------------
  -- data_ready latch
  -----------------------------------------------------------------------------
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

  -----------------------------------------------------------------------------
  -- PAUSE sender (FIX: boolean -> std_logic)
  -----------------------------------------------------------------------------
  pause_sm  <= '1' when ((sm = DO_DECAY) or (sm = WAIT_DECAY)) else '0';
  pause_send <= copying or decaying or pause_sm;

  -----------------------------------------------------------------------------
  -- STATE MACHINE: decay every N packets (FIXED)
  -----------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        sm <= WAIT_DATA;
        pkt_cnt <= (others => '0');
        decay_start_pulse <= '0';
      else
        decay_start_pulse <= '0'; -- default

        case sm is
          when WAIT_DATA =>
            pkt_cnt <= (others => '0');
            if data_ready_p = '1' then
              sm <= STREAMING;
            end if;

          when STREAMING =>
            if send_done_p = '1' then
              if pkt_cnt = to_unsigned(DECAY_EVERY_PKTS-1, pkt_cnt'length) then
                pkt_cnt <= (others => '0');
                sm <= DO_DECAY; -- next: emit 1-cycle start pulse
              else
                pkt_cnt <= pkt_cnt + 1;
              end if;
            end if;

          when DO_DECAY =>
            decay_start_pulse <= '1'; -- 1 cycle
            sm <= WAIT_DECAY;

          when WAIT_DECAY =>
            if decay_done = '1' then
              sm <= STREAMING;
            end if;

          when others =>
            sm <= WAIT_DATA;
        end case;

      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- DECAY/SHIFT module (ubah isi BRAM_B)
  -----------------------------------------------------------------------------
  u_decay : entity work.bram_decay_int16
    generic map (
      DEPTH_BYTES => DEPTH,
      STEP_X      => 10,  -- DEBUG: besar biar kelihatan jelas (ubah bebas)
      STEP_Y      => 0,
      LIMIT_X     => 300,  -- DEBUG: range besar
      LIMIT_Y     => 0
    )
    port map (
      clk_i      => clk_i,
      rstn_i     => rstn_i,
      start_i    => decay_start_pulse,

      b_raddr_o  => b_raddr_dec,
      b_rdata_i  => b_rdata,

      b_we_o     => b_we_dec,
      b_waddr_o  => b_waddr_dec,
      b_wdata_o  => b_wdata_dec,

      done_o     => decay_done,
      busy_o     => decaying
    );

  -----------------------------------------------------------------------------
  -- SEND (B -> UART) packet module
  -----------------------------------------------------------------------------
  u_send : entity work.bram_send_packet_sumchk
    generic map (
      DEPTH     => DEPTH,
      CLOCK_HZ  => CLOCK_FREQUENCY,
      STREAM_HZ => 50
    )
    port map (
      clk_i        => clk_i,
      rstn_i       => rstn_i,
      start_i      => '1',
      continuous_i => '1',
      pause_i      => pause_send,

      b_raddr_o    => b_raddr_send,
      b_rdata_i    => b_rdata,

      tx_busy_i    => tx_busy,
      tx_done_i    => tx_done,
      tx_start_o   => tx_start,
      tx_data_o    => tx_data,

      done_o       => send_done_p,   -- pulse per packet
      busy_o       => sending
    );

  -----------------------------------------------------------------------------
  -- UART TX
  -----------------------------------------------------------------------------
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

  -----------------------------------------------------------------------------
  -- LEDs active-low
  -- 0=sending, 1=copying, 2=locked, 3=full_seen, 4=decaying, 5=data_ready
  -----------------------------------------------------------------------------
  gpio_o <= (
    0 => std_ulogic(not sending),
    1 => std_ulogic(not copying),
    2 => std_ulogic(not locked),
    3 => std_ulogic(not full_rx_store),
    4 => std_ulogic(not decaying),
    5 => std_ulogic(not data_ready_p)
  );

end architecture;
