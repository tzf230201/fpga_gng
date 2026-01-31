library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity blinker is
  generic (
    CLOCK_FREQUENCY : natural := 27_000_000; -- Hz
    BLINK_HZ         : natural := 1          -- period 1s, toggle tiap 0.5s
  );
  port (
    clk_i       : in  std_logic;
    rstn_i      : in  std_logic;   -- active-low reset
    led_level_o : out std_logic;   -- level (aktif-high) untuk "LED ON" secara logika
    tick_o      : out std_logic    -- pulse 1 clock setiap toggle
  );
end entity;

architecture rtl of blinker is
  constant HALF_PERIOD_TICKS : natural := CLOCK_FREQUENCY / (2 * BLINK_HZ);

  signal cnt       : unsigned(31 downto 0) := (others => '0');
  signal led_level : std_logic := '0';
  signal tick      : std_logic := '0';
begin
  led_level_o <= led_level;
  tick_o      <= tick;

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      tick <= '0'; -- default tiap cycle

      if rstn_i = '0' then
        cnt       <= (others => '0');
        led_level <= '0';
        tick      <= '0';
      else
        if cnt = to_unsigned(HALF_PERIOD_TICKS - 1, cnt'length) then
          cnt       <= (others => '0');
          led_level <= not led_level;
          tick      <= '1'; -- 1-clock pulse saat toggle
        else
          cnt <= cnt + 1;
        end if;
      end if;
    end if;
  end process;

end architecture;

--  signal led_level   : std_logic := '0';
--  signal blink_tick  : std_logic := '0';
--  u_blink : entity work.blinker
--    generic map (
--      CLOCK_FREQUENCY => CLOCK_FREQUENCY,
--      BLINK_HZ         => 1
--    )
--    port map (
--      clk_i       => clk_i,
--      rstn_i      => rstn_i,
--      led_level_o => led_level,
--      tick_o      => blink_tick
--    );