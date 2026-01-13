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

  -- store <-> copy_send
  signal full_p   : std_logic;
  signal locked   : std_logic;
  signal a_raddr  : unsigned(8 downto 0);
  signal a_rdata  : std_logic_vector(7 downto 0);

  signal copying  : std_logic;
  signal sending  : std_logic;
  signal cas_done : std_logic;

begin
  -- UART RX
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

  -- RX STORE (BRAM_A inside)
  u_store : entity work.rx_store
    generic map (
      DEPTH => DEPTH
    )
    port map (
      clk_i      => clk_i,
      rstn_i     => rstn_i,
      rx_valid_i => rx_valid,
      rx_data_i  => rx_data,
      hold_i     => (copying or sending), -- extra safety
      clear_i    => cas_done,
      full_o     => full_p,
      raddr_i    => a_raddr,
      rdata_o    => a_rdata,
      locked_o   => locked
    );

  -- COPY + SEND
  u_cas : entity work.bram_copy_and_send
    generic map (
      DEPTH => DEPTH
    )
    port map (
      clk_i      => clk_i,
      rstn_i     => rstn_i,
      start_i    => full_p,
      a_raddr_o  => a_raddr,
      a_rdata_i  => a_rdata,
      tx_busy_i  => tx_busy,
      tx_done_i  => tx_done,
      tx_start_o => tx_start,
      tx_data_o  => tx_data,
      done_o     => cas_done,
      copying_o  => copying,
      sending_o  => sending
    );

  -- UART TX
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

  -- LED active-low:
  -- LED0 = sending, LED1 = copying, LED2 = locked (optional debug)
  gpio_o <= (
    0 => std_ulogic(not sending),
    1 => std_ulogic(not copying),
    2 => std_ulogic(not locked),
    others => '1'
  );

end architecture;
