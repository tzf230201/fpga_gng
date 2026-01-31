library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
  generic (
    CLOCK_FREQUENCY : natural := 27_000_000;
    BAUD            : natural := 1_000_000
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;  -- active-low reset

    start_i : in  std_logic;  -- pulse 1 clk untuk mulai kirim
    data_i  : in  std_logic_vector(7 downto 0);

    txd_o   : out std_logic;  -- UART TX
    busy_o  : out std_logic;  -- '1' saat sedang transmit
    done_o  : out std_logic   -- pulse 1 clk saat selesai
  );
end entity;

architecture rtl of uart_tx is
  constant CLKS_PER_BIT : natural := CLOCK_FREQUENCY / BAUD;

  type state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
  signal state   : state_t := IDLE;

  signal clk_cnt : unsigned(31 downto 0) := (others => '0');
  signal bit_idx : integer range 0 to 7 := 0;
  signal shreg   : std_logic_vector(7 downto 0) := (others => '0');

  signal txd     : std_logic := '1';
  signal busy    : std_logic := '0';
  signal done    : std_logic := '0';
begin
  -- Optional: pastikan pembagian pas (untuk Tang Nano 9K 27MHz & 1Mbps => 27 pas)
  assert (CLOCK_FREQUENCY mod BAUD = 0)
    report "CLOCK_FREQUENCY must be divisible by BAUD for this simple UART"
    severity failure;

  txd_o  <= txd;
  busy_o <= busy;
  done_o <= done;

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      done <= '0'; -- default

      if rstn_i = '0' then
        state   <= IDLE;
        clk_cnt <= (others => '0');
        bit_idx <= 0;
        shreg   <= (others => '0');
        txd     <= '1';
        busy    <= '0';
        done    <= '0';

      else
        case state is
          when IDLE =>
            txd  <= '1';
            busy <= '0';
            clk_cnt <= (others => '0');

            if start_i = '1' then
              shreg   <= data_i;
              busy    <= '1';
              state   <= START_BIT;
              txd     <= '0'; -- start bit
              clk_cnt <= (others => '0');
              bit_idx <= 0;
            end if;

          when START_BIT =>
            if clk_cnt = to_unsigned(CLKS_PER_BIT - 1, clk_cnt'length) then
              clk_cnt <= (others => '0');
              state   <= DATA_BITS;
              txd     <= shreg(0); -- LSB first
            else
              clk_cnt <= clk_cnt + 1;
            end if;

          when DATA_BITS =>
            if clk_cnt = to_unsigned(CLKS_PER_BIT - 1, clk_cnt'length) then
              clk_cnt <= (others => '0');
              if bit_idx = 7 then
                state <= STOP_BIT;
                txd   <= '1'; -- stop bit
              else
                bit_idx <= bit_idx + 1;
                txd     <= shreg(bit_idx + 1);
              end if;
            else
              clk_cnt <= clk_cnt + 1;
            end if;

          when STOP_BIT =>
            if clk_cnt = to_unsigned(CLKS_PER_BIT - 1, clk_cnt'length) then
              clk_cnt <= (others => '0');
              state   <= IDLE;
              busy    <= '0';
              txd     <= '1';
              done    <= '1'; -- 1-cycle pulse
            else
              clk_cnt <= clk_cnt + 1;
            end if;

        end case;
      end if;
    end if;
  end process;
end architecture;

--   TX
--  signal tx_start : std_logic := '0';
--  signal tx_busy  : std_logic;
--  signal tx_done  : std_logic;
--  signal txd      : std_logic;
--  u_tx : entity work.uart_tx
--    generic map (
--      CLOCK_FREQUENCY => CLOCK_FREQUENCY,
--      BAUD            => BAUD
--    )
--    port map (
--      clk_i   => clk_i,
--      rstn_i  => rstn_i,
--      start_i => tx_start,
--      data_i  => buf_data,
--      txd_o   => txd,
--      busy_o  => tx_busy,
--      done_o  => tx_done
--    );
