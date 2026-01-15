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

  -- BRAM_A (external)
  type mem_a_t is array (0 to DEPTH-1) of std_logic_vector(7 downto 0);
  signal mem_a : mem_a_t;

  signal a_we    : std_logic;
  signal a_waddr : unsigned(8 downto 0);
  signal a_wdata : std_logic_vector(7 downto 0);

  signal a_raddr : unsigned(8 downto 0);
  signal a_rdata : std_logic_vector(7 downto 0);

  -- RX store control
  signal full_p   : std_logic;
  signal locked   : std_logic;

  -- delay start copy 1-cycle (last byte commits next edge)
  signal full_p_dly : std_logic := '0';

  -- BRAM_B (buffer)
  type mem_b_t is array (0 to DEPTH-1) of std_logic_vector(7 downto 0);
  signal mem_b : mem_b_t;

  signal b_we    : std_logic;
  signal b_waddr : unsigned(8 downto 0);
  signal b_wdata : std_logic_vector(7 downto 0);

  signal b_raddr : unsigned(8 downto 0);
  signal b_rdata : std_logic_vector(7 downto 0);

  -- copy/send
  signal copying   : std_logic;
  signal sending   : std_logic;
  signal cas_done  : std_logic;
  signal copy_done : std_logic;

  -- debug
  signal full_rx_store : std_logic := '0';

begin

  -- debug latch
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

  -- delay full 1-cycle for copy start
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

  -- BRAM_A (sync write + sync read)
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if a_we = '1' then
        mem_a(to_integer(a_waddr)) <= a_wdata;
      end if;
      a_rdata <= mem_a(to_integer(a_raddr));
    end if;
  end process;

  -- BRAM_B (sync write + sync read)
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if b_we = '1' then
        mem_b(to_integer(b_waddr)) <= b_wdata;
      end if;
      b_rdata <= mem_b(to_integer(b_raddr));
    end if;
  end process;

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

  -- RX STORE controller (RAM outside)
  u_store : entity work.rx_store_ext
    generic map ( DEPTH => DEPTH )
    port map (
      clk_i        => clk_i,
      rstn_i       => rstn_i,
      rx_valid_i   => rx_valid,
      rx_data_i    => rx_data,
      hold_i       => (copying or sending),
      clear_i      => cas_done,
      full_o       => full_p,

      mem_we_o     => a_we,
      mem_waddr_o  => a_waddr,
      mem_wdata_o  => a_wdata,

      mem_raddr_i  => a_raddr,
      mem_rdata_i  => a_rdata,

      rdata_o      => open,
      locked_o     => locked
    );

  -- COPY (A -> B)
  u_copy : entity work.bram_copy
    generic map ( DEPTH => DEPTH )
    port map (
      clk_i     => clk_i,
      rstn_i    => rstn_i,
      start_i   => full_p_dly,

      a_raddr_o => a_raddr,
      a_rdata_i => a_rdata,

      b_waddr_o => b_waddr,
      b_wdata_o => b_wdata,
      b_we_o    => b_we,

      done_o    => copy_done,
      busy_o    => copying
    );

  -- SEND (B -> UART)
  u_send : entity work.bram_send
    generic map ( DEPTH => DEPTH )
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

  -- LEDs active-low
  gpio_o <= (
    0 => std_ulogic(not sending),
    1 => std_ulogic(not copying),
    2 => std_ulogic(not locked),
    3 => std_ulogic(not full_rx_store),
    others => '1'
  );

end architecture;
