library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bram_send is
  generic (
    DEPTH : natural := 400
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;

    start_i : in  std_logic; -- LEVEL start

    -- BRAM_B read (sync)
    b_raddr_o : out unsigned(8 downto 0);
    b_rdata_i : in  std_logic_vector(7 downto 0);

    -- UART TX
    tx_busy_i  : in  std_logic;
    tx_done_i  : in  std_logic;
    tx_start_o : out std_logic;
    tx_data_o  : out std_logic_vector(7 downto 0);

    done_o  : out std_logic; -- pulse
    busy_o  : out std_logic
  );
end entity;

architecture rtl of bram_send is
  constant PTR_W : natural := 9;

  type st_t is (
    IDLE,
    PRIME,
    SET_ADDR,
    WAIT_DATA,
    WAIT_TXIDLE,
    WAIT_DONE,
    ADV
  );
  signal st : st_t := IDLE;

  signal idx      : unsigned(PTR_W-1 downto 0) := (others => '0');
  signal data_reg : std_logic_vector(7 downto 0) := (others => '0');
begin
  b_raddr_o <= idx;
  tx_data_o <= data_reg;

  busy_o <= '1' when st /= IDLE else '0';

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      tx_start_o <= '0';
      done_o     <= '0';

      if rstn_i = '0' then
        st  <= IDLE;
        idx <= (others => '0');

      else
        case st is
          when IDLE =>
            if start_i = '1' then
              idx <= (others => '0'); -- set idx=0 dulu
              st  <= PRIME;           -- tunggu 1 clock supaya b_rdata jadi addr=0
            end if;

          when PRIME =>
            st <= SET_ADDR;

          when SET_ADDR =>
            st <= WAIT_DATA; -- BRAM latency

          when WAIT_DATA =>
            data_reg <= b_rdata_i;
            st <= WAIT_TXIDLE;

          when WAIT_TXIDLE =>
            if tx_busy_i = '0' then
              tx_start_o <= '1';
              st <= WAIT_DONE;
            end if;

          when WAIT_DONE =>
            if tx_done_i = '1' then
              st <= ADV;
            end if;

          when ADV =>
            if idx = to_unsigned(DEPTH-1, PTR_W) then
              done_o <= '1'; -- 1-cycle pulse
              st <= IDLE;
            else
              idx <= idx + 1;
              st <= SET_ADDR;
            end if;

        end case;
      end if;
    end if;
  end process;
end architecture;
