library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bram_send_400 is
  generic (
    DEPTH : natural := 400
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic; -- active-low

    start_i : in  std_logic; -- pulse/level ok (edge-detect internal)

    raddr_o : out unsigned(8 downto 0);
    rdata_i : in  std_logic_vector(7 downto 0); -- SYNC read 1-cycle

    tx_busy_i  : in  std_logic;
    tx_done_i  : in  std_logic;

    tx_start_o : out std_logic;
    tx_data_o  : out std_logic_vector(7 downto 0);

    sending_o  : out std_logic
  );
end entity;

architecture rtl of bram_send_400 is
  constant PTR_W : natural := 9;

  type st_t is (S_IDLE, S_SET_ADDR, S_WAIT_DATA, S_LATCH, S_WAIT_TXIDLE, S_WAIT_DONE, S_ADV);
  signal st : st_t := S_IDLE;

  signal idx      : unsigned(PTR_W-1 downto 0) := (others => '0');
  signal data_reg : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_start : std_logic := '0';

  -- edge detect start & done
  signal start_d : std_logic := '0';
  signal done_d  : std_logic := '0';
  signal start_p : std_logic := '0';
  signal done_p  : std_logic := '0';

  function U(n : natural; w : natural) return unsigned is
  begin
    return to_unsigned(n, w);
  end function;

begin
  raddr_o    <= idx;
  tx_start_o <= tx_start;
  tx_data_o  <= data_reg;

  sending_o <= '1' when st /= S_IDLE else '0';

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      tx_start <= '0';

      -- edge detect
      start_p <= start_i and (not start_d);
      done_p  <= tx_done_i and (not done_d);
      start_d <= start_i;
      done_d  <= tx_done_i;

      if rstn_i = '0' then
        st       <= S_IDLE;
        idx      <= (others => '0');
        data_reg <= (others => '0');
        start_d  <= '0';
        done_d   <= '0';
        start_p  <= '0';
        done_p   <= '0';

      else
        case st is
          when S_IDLE =>
            idx <= (others => '0');
            if start_p = '1' then
              st <= S_SET_ADDR;
            end if;

          when S_SET_ADDR =>
            st <= S_WAIT_DATA;

          when S_WAIT_DATA =>
            st <= S_LATCH;

          when S_LATCH =>
            data_reg <= rdata_i;      -- latch BRAM byte
            st <= S_WAIT_TXIDLE;

          when S_WAIT_TXIDLE =>
            if tx_busy_i = '0' then
              tx_start <= '1';
              st <= S_WAIT_DONE;
            end if;

          when S_WAIT_DONE =>
            if done_p = '1' then
              st <= S_ADV;
            end if;

          when S_ADV =>
            if idx = U(DEPTH-1, PTR_W) then
              st  <= S_IDLE;
              idx <= (others => '0');
            else
              idx <= idx + 1;
              st  <= S_SET_ADDR;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture;
