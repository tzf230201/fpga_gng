library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bram_send_word32_sumchk is
  generic (
    WORDS     : natural := 100;
    CLOCK_HZ  : natural := 27_000_000;
    STREAM_HZ : natural := 50
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i      : in std_logic;
    continuous_i : in std_logic;
    pause_i      : in std_logic;

    -- read mem_c (sync 1-cycle)
    c_raddr_o : out unsigned(6 downto 0);
    c_rdata_i : in  std_logic_vector(31 downto 0);

    -- UART TX handshake
    tx_busy_i  : in  std_logic;
    tx_done_i  : in  std_logic;
    tx_start_o : out std_logic;
    tx_data_o  : out std_logic_vector(7 downto 0);

    done_o : out std_logic;
    busy_o : out std_logic
  );
end entity;

architecture rtl of bram_send_word32_sumchk is
  constant PAYLOAD_BYTES : natural := WORDS*4;
  constant TICKS_PER_PKT : natural := CLOCK_HZ/STREAM_HZ;

  type st_t is (
    IDLE, WAIT_TICK,
    SEND_FF1, WAIT_FF1,
    SEND_FF2, WAIT_FF2,
    SEND_LEN0, WAIT_LEN0,
    SEND_LEN1, WAIT_LEN1,
    SEND_SEQ,  WAIT_SEQ,
    RD_SET, RD_WAIT, RD_LATCH,
    SEND_B0, WAIT_B0,
    SEND_B1, WAIT_B1,
    SEND_B2, WAIT_B2,
    SEND_B3, WAIT_B3,
    SEND_CHK, WAIT_CHK,
    FINISH
  );

  signal st : st_t := IDLE;

  signal tick_cnt : unsigned(31 downto 0) := (others => '0');
  signal seq      : unsigned(7 downto 0) := (others => '0');

  signal word_idx : unsigned(6 downto 0) := (others => '0');
  signal word_reg : std_logic_vector(31 downto 0) := (others => '0');

  signal chk      : unsigned(7 downto 0) := (others => '0');

  signal c_raddr  : unsigned(6 downto 0) := (others => '0');

  function u8(v : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(v, 8));
  end function;

  function lo8(v : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(v, 16)(7 downto 0));
  end function;

  function hi8(v : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(v, 16)(15 downto 8));
  end function;

begin
  c_raddr_o <= c_raddr;

  process(clk_i)
    procedure kick_send(b : std_logic_vector(7 downto 0)) is
    begin
      tx_data_o  <= b;
      tx_start_o <= '1';
    end procedure;
  begin
    if rising_edge(clk_i) then
      tx_start_o <= '0';
      done_o     <= '0';

      if rstn_i = '0' then
        st <= IDLE;
        tick_cnt <= (others => '0');
        seq <= (others => '0');
        word_idx <= (others => '0');
        word_reg <= (others => '0');
        chk <= (others => '0');
        c_raddr <= (others => '0');
      else
        if pause_i = '1' then
          -- hold state, do nothing
          null;
        else
          case st is
            when IDLE =>
              tick_cnt <= (others => '0');
              if start_i = '1' then
                st <= WAIT_TICK;
              end if;

            when WAIT_TICK =>
              if tick_cnt = to_unsigned(TICKS_PER_PKT-1, tick_cnt'length) then
                tick_cnt <= (others => '0');
                st <= SEND_FF1;
              else
                tick_cnt <= tick_cnt + 1;
              end if;

            when SEND_FF1 =>
              if tx_busy_i = '0' then
                kick_send(x"FF");
                st <= WAIT_FF1;
              end if;

            when WAIT_FF1 =>
              if tx_done_i = '1' then st <= SEND_FF2; end if;

            when SEND_FF2 =>
              if tx_busy_i = '0' then
                kick_send(x"FF");
                st <= WAIT_FF2;
              end if;

            when WAIT_FF2 =>
              if tx_done_i = '1' then st <= SEND_LEN0; end if;

            when SEND_LEN0 =>
              if tx_busy_i = '0' then
                kick_send(lo8(PAYLOAD_BYTES));
                st <= WAIT_LEN0;
              end if;

            when WAIT_LEN0 =>
              if tx_done_i = '1' then st <= SEND_LEN1; end if;

            when SEND_LEN1 =>
              if tx_busy_i = '0' then
                kick_send(hi8(PAYLOAD_BYTES));
                st <= WAIT_LEN1;
              end if;

            when WAIT_LEN1 =>
              if tx_done_i = '1' then st <= SEND_SEQ; end if;

            when SEND_SEQ =>
              if tx_busy_i = '0' then
                kick_send(std_logic_vector(seq));
                chk <= (others => '0');
                word_idx <= (others => '0');
                st <= WAIT_SEQ;
              end if;

            when WAIT_SEQ =>
              if tx_done_i = '1' then st <= RD_SET; end if;

            -- read word
            when RD_SET =>
              c_raddr <= word_idx;
              st <= RD_WAIT;

            when RD_WAIT =>
              st <= RD_LATCH;

            when RD_LATCH =>
              word_reg <= c_rdata_i;
              st <= SEND_B0;

            -- send 4 bytes (little endian as stored)
            when SEND_B0 =>
              if tx_busy_i = '0' then
                kick_send(word_reg(7 downto 0));
                chk <= chk + unsigned(word_reg(7 downto 0));
                st <= WAIT_B0;
              end if;

            when WAIT_B0 =>
              if tx_done_i = '1' then st <= SEND_B1; end if;

            when SEND_B1 =>
              if tx_busy_i = '0' then
                kick_send(word_reg(15 downto 8));
                chk <= chk + unsigned(word_reg(15 downto 8));
                st <= WAIT_B1;
              end if;

            when WAIT_B1 =>
              if tx_done_i = '1' then st <= SEND_B2; end if;

            when SEND_B2 =>
              if tx_busy_i = '0' then
                kick_send(word_reg(23 downto 16));
                chk <= chk + unsigned(word_reg(23 downto 16));
                st <= WAIT_B2;
              end if;

            when WAIT_B2 =>
              if tx_done_i = '1' then st <= SEND_B3; end if;

            when SEND_B3 =>
              if tx_busy_i = '0' then
                kick_send(word_reg(31 downto 24));
                chk <= chk + unsigned(word_reg(31 downto 24));
                st <= WAIT_B3;
              end if;

            when WAIT_B3 =>
              if tx_done_i = '1' then
                if word_idx = to_unsigned(WORDS-1, word_idx'length) then
                  st <= SEND_CHK;
                else
                  word_idx <= word_idx + 1;
                  st <= RD_SET;
                end if;
              end if;

            when SEND_CHK =>
              if tx_busy_i = '0' then
                kick_send(std_logic_vector(chk));
                st <= WAIT_CHK;
              end if;

            when WAIT_CHK =>
              if tx_done_i = '1' then st <= FINISH; end if;

            when FINISH =>
              done_o <= '1';
              seq <= seq + 1;
              if continuous_i = '1' then
                st <= WAIT_TICK;
              else
                st <= IDLE;
              end if;

            when others =>
              st <= IDLE;
          end case;
        end if;
      end if;
    end if;
  end process;

  busy_o <= '0' when (st = IDLE) else '1';
end architecture;
