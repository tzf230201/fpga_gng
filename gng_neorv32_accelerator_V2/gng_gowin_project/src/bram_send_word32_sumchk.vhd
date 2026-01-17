library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bram_send_word32_sumchk is
  generic (
    WORDS     : natural := 100;         -- 100 word32 -> payload 400 bytes
    CLOCK_HZ  : natural := 27_000_000;
    STREAM_HZ : natural := 50
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i      : in  std_logic;
    continuous_i : in  std_logic;
    pause_i      : in  std_logic;

    -- BRAM_C read (sync read 1-cycle)
    c_raddr_o : out unsigned(6 downto 0);
    c_rdata_i : in  std_logic_vector(31 downto 0);

    -- UART TX handshake
    tx_busy_i  : in  std_logic;
    tx_done_i  : in  std_logic;
    tx_start_o : out std_logic;
    tx_data_o  : out std_logic_vector(7 downto 0);

    done_o : out std_logic; -- pulse per packet (after checksum DONE)
    busy_o : out std_logic
  );
end entity;

architecture rtl of bram_send_word32_sumchk is
  constant PAYLOAD_LEN : natural := WORDS*4; -- 400 bytes
  constant LEN16       : unsigned(15 downto 0) := to_unsigned(PAYLOAD_LEN, 16);
  constant LEN0        : std_logic_vector(7 downto 0) := std_logic_vector(LEN16(7 downto 0));
  constant LEN1        : std_logic_vector(7 downto 0) := std_logic_vector(LEN16(15 downto 8));

  -- pacing
  constant TICK_DIV : natural := (CLOCK_HZ / STREAM_HZ);
  signal tick_cnt : unsigned(31 downto 0) := (others => '0');
  signal tick_p   : std_logic := '0';

  type st_t is (
    IDLE,

    S_FF1,  W_FF1,
    S_FF2,  W_FF2,
    S_LEN0, W_LEN0,
    S_LEN1, W_LEN1,
    S_SEQ,  W_SEQ,

    RD_SET, RD_WAIT, RD_LATCH,

    S_B0, W_B0,
    S_B1, W_B1,
    S_B2, W_B2,
    S_B3, W_B3,

    S_CHK, W_CHK
  );
  signal st : st_t := IDLE;

  signal tx_start : std_logic := '0';
  signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');

  signal seq : unsigned(7 downto 0) := (others => '0');

  signal widx : unsigned(6 downto 0) := (others => '0');
  signal wreg : std_logic_vector(31 downto 0) := (others => '0');

  signal chk : unsigned(7 downto 0) := (others => '0');

  signal done_p : std_logic := '0';

  -- latch start
  signal start_latched : std_logic := '0';

begin
  tx_start_o <= tx_start;
  tx_data_o  <= tx_data;

  done_o <= done_p;
  busy_o <= '0' when st = IDLE else '1';

  c_raddr_o <= widx;

  -- tick generator (only in IDLE)
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      tick_p <= '0';
      if rstn_i = '0' then
        tick_cnt <= (others => '0');
      else
        if st = IDLE then
          if tick_cnt = 0 then
            tick_cnt <= to_unsigned(TICK_DIV-1, tick_cnt'length);
            tick_p <= '1';
          else
            tick_cnt <= tick_cnt - 1;
          end if;
        else
          tick_cnt <= to_unsigned(TICK_DIV-1, tick_cnt'length);
        end if;
      end if;
    end if;
  end process;

  process(clk_i)
    variable b0, b1, b2, b3 : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk_i) then
      tx_start <= '0';
      done_p   <= '0';

      if rstn_i = '0' then
        st <= IDLE;
        seq <= (others => '0');
        widx <= (others => '0');
        wreg <= (others => '0');
        chk <= (others => '0');
        start_latched <= '0';

      else
        if start_i = '1' then
          start_latched <= '1';
        end if;

        case st is
          when IDLE =>
            if pause_i = '1' then
              null;
            else
              if start_latched = '1' then
                if (continuous_i = '1' and tick_p = '1') or (continuous_i = '0') then
                  chk  <= (others => '0');
                  widx <= (others => '0');
                  st   <= S_FF1;
                end if;
              end if;
            end if;

          -- --- HEADER FF FF LEN(2) SEQ ---
          when S_FF1 =>
            if pause_i='0' and tx_busy_i='0' then
              tx_data <= x"FF"; tx_start <= '1';
              st <= W_FF1;
            end if;
          when W_FF1 =>
            if tx_done_i='1' then st <= S_FF2; end if;

          when S_FF2 =>
            if pause_i='0' and tx_busy_i='0' then
              tx_data <= x"FF"; tx_start <= '1';
              st <= W_FF2;
            end if;
          when W_FF2 =>
            if tx_done_i='1' then st <= S_LEN0; end if;

          when S_LEN0 =>
            if pause_i='0' and tx_busy_i='0' then
              tx_data <= LEN0; tx_start <= '1';
              st <= W_LEN0;
            end if;
          when W_LEN0 =>
            if tx_done_i='1' then st <= S_LEN1; end if;

          when S_LEN1 =>
            if pause_i='0' and tx_busy_i='0' then
              tx_data <= LEN1; tx_start <= '1';
              st <= W_LEN1;
            end if;
          when W_LEN1 =>
            if tx_done_i='1' then st <= S_SEQ; end if;

          when S_SEQ =>
            if pause_i='0' and tx_busy_i='0' then
              tx_data <= std_logic_vector(seq); tx_start <= '1';
              st <= W_SEQ;
            end if;
          when W_SEQ =>
            if tx_done_i='1' then
              -- payload starts: checksum reset
              chk  <= (others => '0');
              widx <= (others => '0');
              st <= RD_SET;
            end if;

          -- --- BRAM READ (sync 1-cycle) ---
          when RD_SET =>
            st <= RD_WAIT;
          when RD_WAIT =>
            st <= RD_LATCH;
          when RD_LATCH =>
            wreg <= c_rdata_i;
            st <= S_B0;

          -- --- PAYLOAD BYTES: xL xH yL yH ---
          when S_B0 =>
            b0 := wreg(7 downto 0);
            if pause_i='0' and tx_busy_i='0' then
              tx_data <= b0; tx_start <= '1';
              chk <= chk + unsigned(b0);
              st <= W_B0;
            end if;
          when W_B0 =>
            if tx_done_i='1' then st <= S_B1; end if;

          when S_B1 =>
            b1 := wreg(15 downto 8);
            if pause_i='0' and tx_busy_i='0' then
              tx_data <= b1; tx_start <= '1';
              chk <= chk + unsigned(b1);
              st <= W_B1;
            end if;
          when W_B1 =>
            if tx_done_i='1' then st <= S_B2; end if;

          when S_B2 =>
            b2 := wreg(23 downto 16);
            if pause_i='0' and tx_busy_i='0' then
              tx_data <= b2; tx_start <= '1';
              chk <= chk + unsigned(b2);
              st <= W_B2;
            end if;
          when W_B2 =>
            if tx_done_i='1' then st <= S_B3; end if;

          when S_B3 =>
            b3 := wreg(31 downto 24);
            if pause_i='0' and tx_busy_i='0' then
              tx_data <= b3; tx_start <= '1';
              chk <= chk + unsigned(b3);
              st <= W_B3;
            end if;
          when W_B3 =>
            if tx_done_i='1' then
              if widx = to_unsigned(WORDS-1, widx'length) then
                st <= S_CHK;
              else
                widx <= widx + 1;
                st <= RD_SET;
              end if;
            end if;

          -- --- CHECKSUM ---
          when S_CHK =>
            if pause_i='0' and tx_busy_i='0' then
              tx_data <= std_logic_vector(chk);
              tx_start <= '1';
              st <= W_CHK;
            end if;

          when W_CHK =>
            if tx_done_i='1' then
              done_p <= '1';
              seq <= seq + 1;
              if continuous_i = '0' then
                start_latched <= '0';
              end if;
              st <= IDLE;
            end if;

          when others =>
            st <= IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture;
