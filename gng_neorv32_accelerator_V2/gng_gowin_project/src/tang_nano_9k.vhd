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

  -- UART RX
  signal rx_data  : std_logic_vector(7 downto 0);
  signal rx_valid : std_logic;
  signal rx_busy  : std_logic;
  signal rx_err   : std_logic;

  -- UART TX
  signal tx_start : std_logic;
  signal tx_data  : std_logic_vector(7 downto 0);
  signal tx_busy  : std_logic;
  signal tx_done  : std_logic;
  signal txd      : std_logic;

  -- RX STORE (BRAM_A)
  signal full_p   : std_logic;
  signal locked   : std_logic;
  signal a_raddr  : unsigned(8 downto 0);
  signal a_rdata  : std_logic_vector(7 downto 0);

  -- Debug / control
  signal copying  : std_logic;
  signal sending  : std_logic;
  signal cas_done : std_logic;

  signal full_rx_store : std_logic := '0';

  -- ============================================================
  -- BRAM_B signals (buffer RAM between copy and send)
  -- ============================================================
  type mem_t is array (0 to DEPTH-1) of std_logic_vector(7 downto 0);
  signal mem_b : mem_t;

  signal b_we    : std_logic;
  signal b_waddr : unsigned(8 downto 0);
  signal b_wdata : std_logic_vector(7 downto 0);

  signal b_raddr : unsigned(8 downto 0);
  signal b_rdata : std_logic_vector(7 downto 0);

  -- >>> FIX: pipeline 1-cycle untuk write port BRAM_B <<<
  signal b_we_q    : std_logic := '0';
  signal b_waddr_q : unsigned(8 downto 0) := (others => '0');
  signal b_wdata_q : std_logic_vector(7 downto 0) := (others => '0');

  -- start/done handshake antara copy dan send
  signal copy_done : std_logic;

begin

  ------------------------------------------------------------------
  -- LATCH full_p for debug LED (level)
  ------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        full_rx_store <= '0';
      elsif full_p = '1' then
        full_rx_store <= '1';
--      elsif cas_done = '1' then
--        full_rx_store <= '0';
      end if;
    end if;
  end process;

-- BRAM_B (sync RAM)
process(clk_i)
begin
  if rising_edge(clk_i) then
    if b_we = '1' then
      mem_b(to_integer(b_waddr)) <= b_wdata;
    end if;
    b_rdata <= mem_b(to_integer(b_raddr));
  end if;
end process;

  ------------------------------------------------------------------
  -- UART RX
  ------------------------------------------------------------------
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

  ------------------------------------------------------------------
  -- RX STORE (BRAM_A inside)
  ------------------------------------------------------------------
  u_store : entity work.rx_store
    generic map (
      DEPTH => DEPTH
    )
    port map (
      clk_i      => clk_i,
      rstn_i     => rstn_i,
      rx_valid_i => rx_valid,
      rx_data_i  => rx_data,
      hold_i     => (copying or sending),
      clear_i    => cas_done,
      full_o     => full_p,
      raddr_i    => a_raddr,
      rdata_o    => a_rdata,
      locked_o   => locked
    );

  ------------------------------------------------------------------
  -- COPY (BRAM_A -> BRAM_B)
  ------------------------------------------------------------------
  u_copy : entity work.bram_copy
    generic map (
      DEPTH => DEPTH
    )
    port map (
      clk_i     => clk_i,
      rstn_i    => rstn_i,
      start_i   => full_p,        -- (kalau kamu punya full_pulse, lebih bagus pakai pulse)
      a_raddr_o => a_raddr,
      a_rdata_i => a_rdata,
      b_waddr_o => b_waddr,
      b_wdata_o => b_wdata,
      b_we_o    => b_we,
      done_o    => copy_done,
      busy_o    => copying
    );

  ------------------------------------------------------------------
  -- SEND (BRAM_B -> UART)
  ------------------------------------------------------------------
  u_send : entity work.bram_send
    generic map (
      DEPTH => DEPTH
    )
    port map (
      clk_i      => clk_i,
      rstn_i     => rstn_i,
      start_i    => copy_done,
      b_raddr_o  => b_raddr,
      b_rdata_i  => b_rdata,
      tx_busy_i  => tx_busy,
      tx_done_i  => tx_done,
      tx_start_o => tx_start,
      tx_data_o  => tx_data,
      done_o     => cas_done,
      busy_o     => sending
    );

  ------------------------------------------------------------------
  -- UART TX
  ------------------------------------------------------------------
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

  ------------------------------------------------------------------
  -- LED active-low:
  -- LED0 = sending, LED1 = copying, LED2 = locked, LED3 = full_rx_store
  ------------------------------------------------------------------
  gpio_o <= (
    0 => std_ulogic(not sending),
    1 => std_ulogic(not copying),
    2 => std_ulogic(not locked),
    3 => std_ulogic(not full_rx_store),
    others => '1'
  );

end architecture;
