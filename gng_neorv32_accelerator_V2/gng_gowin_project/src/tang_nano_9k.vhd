library ieee;
use ieee.std_logic_1164.all;

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
  -- RX
  signal rx_data  : std_logic_vector(7 downto 0);
  signal rx_valid : std_logic;
  signal rx_busy  : std_logic;
  signal rx_err   : std_logic;

  -- TX
  signal tx_start : std_logic;
  signal tx_data  : std_logic_vector(7 downto 0);
  signal tx_busy  : std_logic;
  signal tx_done  : std_logic;
  signal txd      : std_logic;

  signal sending  : std_logic;
begin
  -- UART pins
  uart_txd_o <= std_ulogic(txd);

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

  u_buf : entity work.rx_buffer_400
    generic map (
      DEPTH => 400
    )
    port map (
      clk_i      => clk_i,
      rstn_i     => rstn_i,
      rx_valid_i => rx_valid,
      rx_data_i  => rx_data,
      tx_busy_i  => tx_busy,
      tx_done_i  => tx_done,
      tx_start_o => tx_start,
      tx_data_o  => tx_data,
      sending_o  => sending
    );

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

  -- (opsional) indikator: LED0 nyala saat sedang SEND (ingat active-low)
  gpio_o <= (0 => std_ulogic(not sending), others => '1');

end architecture;

