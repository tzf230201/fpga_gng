library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bram_copy_and_send is
  generic (
    DEPTH : natural := 400
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic; -- active-low

    start_i : in  std_logic; -- pulse/level ok

    -- BRAM_A read (SYNC 1-cycle from rx_store)
    a_raddr_o : out unsigned(8 downto 0);
    a_rdata_i : in  std_logic_vector(7 downto 0);

    -- UART TX handshake
    tx_busy_i : in  std_logic;
    tx_done_i : in  std_logic;

    -- UART TX output
    tx_start_o : out std_logic;
    tx_data_o  : out std_logic_vector(7 downto 0);

    -- done pulse to clear rx_store lock
    done_o     : out std_logic;

    -- debug
    copying_o  : out std_logic;
    sending_o  : out std_logic
  );
end entity;

architecture rtl of bram_copy_and_send is
  constant PTR_W : natural := 9;

  type mem_t is array (0 to DEPTH-1) of std_logic_vector(7 downto 0);
  signal mem_b : mem_t;

  type st_t is (
    S_IDLE,
    S_COPY_SET, S_COPY_WAIT, S_COPY_WRITE,
    S_SEND_LATCH, S_SEND_WAIT_TXIDLE, S_SEND_WAIT_DONE, S_SEND_ADV
  );
  signal st : st_t := S_IDLE;

  signal cp_idx : unsigned(PTR_W-1 downto 0) := (others => '0');
  signal rd_idx : unsigned(PTR_W-1 downto 0) := (others => '0');

  signal data_reg : std_logic_vector(7 downto 0) := (others => '0');

  -- edge detect start & done
  signal start_d : std_logic := '0';
  signal done_d  : std_logic := '0';
  signal start_p : std_logic := '0';
  signal done_p  : std_logic := '0';

  signal tx_start : std_logic := '0';
  signal done_pulse : std_logic := '0';

  function U(n : natural; w : natural) return unsigned is
  begin
    return to_unsigned(n, w);
  end function;

begin
  a_raddr_o  <= cp_idx;

  tx_start_o <= tx_start;
  tx_data_o  <= data_reg;

  done_o <= done_pulse;

  copying_o <= '1' when (st = S_COPY_SET or st = S_COPY_WAIT or st = S_COPY_WRITE) else '0';
  sending_o <= '1' when (st = S_SEND_LATCH or st = S_SEND_WAIT_TXIDLE or st = S_SEND_WAIT_DONE or st = S_SEND_ADV) else '0';

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      tx_start    <= '0';
      done_pulse  <= '0';

      -- edge detect
      start_p <= start_i and (not start_d);
      done_p  <= tx_done_i and (not done_d);
      start_d <= start_i;
      done_d  <= tx_done_i;

      if rstn_i = '0' then
        st        <= S_IDLE;
        cp_idx    <= (others => '0');
        rd_idx    <= (others => '0');
        data_reg  <= (others => '0');
        start_d   <= '0';
        done_d    <= '0';
        start_p   <= '0';
        done_p    <= '0';

      else
        case st is
          when S_IDLE =>
            cp_idx <= (others => '0');
            rd_idx <= (others => '0');
            if start_p = '1' then
              st <= S_COPY_SET;
            end if;

          -- =========================
          -- COPY: BRAM_A (sync) -> mem_b
          -- =========================
          when S_COPY_SET =>
            -- addr already = cp_idx
            st <= S_COPY_WAIT;

          when S_COPY_WAIT =>
            -- wait 1 cycle for a_rdata_i valid
            st <= S_COPY_WRITE;

          when S_COPY_WRITE =>
            mem_b(to_integer(cp_idx)) <= a_rdata_i;

            if cp_idx = U(DEPTH-1, PTR_W) then
              rd_idx <= (others => '0');
              st     <= S_SEND_LATCH;
            else
              cp_idx <= cp_idx + 1;
              st     <= S_COPY_SET;
            end if;

          -- =========================
          -- SEND: from mem_b
          -- =========================
          when S_SEND_LATCH =>
            data_reg <= mem_b(to_integer(rd_idx));
            st <= S_SEND_WAIT_TXIDLE;

          when S_SEND_WAIT_TXIDLE =>
            if tx_busy_i = '0' then
              tx_start <= '1';
              st <= S_SEND_WAIT_DONE;
            end if;

          when S_SEND_WAIT_DONE =>
            if done_p = '1' then
              st <= S_SEND_ADV;
            end if;

          when S_SEND_ADV =>
            if rd_idx = U(DEPTH-1, PTR_W) then
              done_pulse <= '1'; -- one-cycle pulse
              st <= S_IDLE;
            else
              rd_idx <= rd_idx + 1;
              st <= S_SEND_LATCH;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture;
