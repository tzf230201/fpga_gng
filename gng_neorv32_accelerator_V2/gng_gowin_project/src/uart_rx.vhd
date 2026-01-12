library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx is
  generic (
    CLOCK_FREQUENCY : natural := 27_000_000;
    BAUD            : natural := 1_000_000
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;  -- active-low reset

    rxd_i   : in  std_logic;  -- UART RX

    data_o  : out std_logic_vector(7 downto 0);
    valid_o : out std_logic;  -- pulse 1 clk saat byte diterima valid
    busy_o  : out std_logic;  -- '1' saat sedang menerima
    err_o   : out std_logic   -- pulse 1 clk kalau stop-bit salah
  );
end entity;

architecture rtl of uart_rx is
  constant CLKS_PER_BIT : natural := CLOCK_FREQUENCY / BAUD;

  type state_t is (IDLE, START_CHECK, DATA_BITS, STOP_BIT);
  signal state   : state_t := IDLE;

  signal clk_cnt : unsigned(31 downto 0) := (others => '0');
  signal bit_idx : integer range 0 to 7 := 0;
  signal shreg   : std_logic_vector(7 downto 0) := (others => '0');

  signal valid   : std_logic := '0';
  signal busy    : std_logic := '0';
  signal err     : std_logic := '0';

  -- sinkronisasi RX (2 FF) untuk kurangi metastability
  signal rxd_ff1, rxd_ff2 : std_logic := '1';
begin
  assert (CLOCK_FREQUENCY mod BAUD = 0)
    report "CLOCK_FREQUENCY must be divisible by BAUD for this simple UART RX"
    severity failure;

  data_o  <= shreg;
  valid_o <= valid;
  busy_o  <= busy;
  err_o   <= err;

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      -- sync RX
      rxd_ff1 <= rxd_i;
      rxd_ff2 <= rxd_ff1;

      valid <= '0';
      err   <= '0';

      if rstn_i = '0' then
        state   <= IDLE;
        clk_cnt <= (others => '0');
        bit_idx <= 0;
        shreg   <= (others => '0');
        busy    <= '0';

      else
        case state is
          when IDLE =>
            busy    <= '0';
            clk_cnt <= (others => '0');
            bit_idx <= 0;

            -- detect start bit (falling to 0)
            if rxd_ff2 = '0' then
              busy    <= '1';
              state   <= START_CHECK;
              clk_cnt <= (others => '0');
            end if;

          when START_CHECK =>
            -- tunggu setengah bit, cek masih 0 (valid start)
            if clk_cnt = to_unsigned((CLKS_PER_BIT/2) - 1, clk_cnt'length) then
              clk_cnt <= (others => '0');
              if rxd_ff2 = '0' then
                state   <= DATA_BITS;
                bit_idx <= 0;
              else
                -- false start
                state <= IDLE;
                busy  <= '0';
              end if;
            else
              clk_cnt <= clk_cnt + 1;
            end if;

          when DATA_BITS =>
            -- sample tiap 1 bit
            if clk_cnt = to_unsigned(CLKS_PER_BIT - 1, clk_cnt'length) then
              clk_cnt <= (others => '0');

              -- LSB first
              shreg(bit_idx) <= rxd_ff2;

              if bit_idx = 7 then
                state <= STOP_BIT;
              else
                bit_idx <= bit_idx + 1;
              end if;
            else
              clk_cnt <= clk_cnt + 1;
            end if;

          when STOP_BIT =>
            if clk_cnt = to_unsigned(CLKS_PER_BIT - 1, clk_cnt'length) then
              clk_cnt <= (others => '0');
              busy    <= '0';

              if rxd_ff2 = '1' then
                valid <= '1'; -- 1-cycle pulse
              else
                err <= '1';   -- stop bit salah
              end if;

              state <= IDLE;
            else
              clk_cnt <= clk_cnt + 1;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture;


--  signal rx_data  : std_logic_vector(7 downto 0);
--  signal rx_valid : std_logic;
--  signal rx_busy  : std_logic;
--  signal rx_err   : std_logic;

--   RX instance
--  u_rx : entity work.uart_rx
--    generic map (
--      CLOCK_FREQUENCY => CLOCK_FREQUENCY,
--      BAUD            => BAUD
--    )
--    port map (
--      clk_i   => clk_i,
--      rstn_i  => rstn_i,
--      rxd_i   => std_logic(uart_rxd_i),
--      data_o  => rx_data,
--      valid_o => rx_valid,
--      busy_o  => rx_busy,
--      err_o   => rx_err
--    );
