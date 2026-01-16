library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bram_send_packet_sumchk is
  generic (
    DEPTH     : natural := 400;        -- payload bytes (LEN)
    CLOCK_HZ  : natural := 27_000_000;  -- FPGA clock
    STREAM_HZ : natural := 50           -- packets per second
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;

    start_i      : in  std_logic;        -- pulse/level ok
    continuous_i : in  std_logic := '0'; -- '1' = repeat forever
    pause_i      : in  std_logic := '0'; -- '1' = freeze FSM

    -- BRAM read (SYNC 1-cycle latency)
    b_raddr_o : out unsigned(8 downto 0);
    b_rdata_i : in  std_logic_vector(7 downto 0);

    -- UART TX handshake
    tx_busy_i : in  std_logic;
    tx_done_i : in  std_logic;

    -- UART TX output
    tx_start_o : out std_logic;
    tx_data_o  : out std_logic_vector(7 downto 0);

    done_o : out std_logic; -- pulse when one packet finished
    busy_o : out std_logic
  );
end entity;

architecture rtl of bram_send_packet_sumchk is
  constant PTR_W : natural := 9;

  -- gap cycles for STREAM_HZ
  constant GAP_CYCLES : natural := CLOCK_HZ / STREAM_HZ;

  function clog2(n : natural) return natural is
    variable r : natural := 0;
    variable v : natural := 1;
  begin
    while v < n loop
      v := v * 2;
      r := r + 1;
    end loop;
    return r;
  end function;

  constant GAP_W : natural := clog2(GAP_CYCLES + 1);

  -- LEN bytes little-endian
  constant LEN_VEC : unsigned(15 downto 0) := to_unsigned(DEPTH, 16);
  constant LEN0    : std_logic_vector(7 downto 0) := std_logic_vector(LEN_VEC(7 downto 0));
  constant LEN1    : std_logic_vector(7 downto 0) := std_logic_vector(LEN_VEC(15 downto 8));

  type st_t is (
    IDLE,

    H0_WAITIDLE, H0_FIRE, H0_WAITDONE,
    H1_WAITIDLE, H1_FIRE, H1_WAITDONE,

    LEN0_WAITIDLE, LEN0_FIRE, LEN0_WAITDONE,
    LEN1_WAITIDLE, LEN1_FIRE, LEN1_WAITDONE,

    SEQ_WAITIDLE, SEQ_FIRE, SEQ_WAITDONE,

    -- payload (sync BRAM 1-cycle)
    PAY_SET_ADDR,
    PAY_WAITDATA,
    PAY_LATCH,        -- latch b_rdata_i -> data_reg
    PAY_WAITIDLE,
    PAY_FIRE,
    PAY_WAITDONE,
    PAY_ADV,

    -- checksum byte
    CHK_WAITIDLE,
    CHK_FIRE,
    CHK_WAITDONE,

    FINISH,
    GAP_WAIT
  );

  signal st : st_t := IDLE;

  signal idx      : unsigned(PTR_W-1 downto 0) := (others => '0');
  signal data_reg : std_logic_vector(7 downto 0) := (others => '0');

  signal tx_start   : std_logic := '0';
  signal tx_data    : std_logic_vector(7 downto 0) := (others => '0');
  signal done_pulse : std_logic := '0';

  -- edge detect start
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  -- edge detect tx_done
  signal done_d : std_logic := '0';
  signal done_p : std_logic := '0';

  -- sequence counter
  signal seq : unsigned(7 downto 0) := (others => '0');

  -- gap counter
  signal gap_cnt : unsigned(GAP_W-1 downto 0) := (others => '0');

  -- checksum accumulator (SUM8 of payload)
  signal chk_acc : unsigned(7 downto 0) := (others => '0');

  function U(n : natural; w : natural) return unsigned is
  begin
    return to_unsigned(n, w);
  end function;

begin
  b_raddr_o <= idx;

  tx_start_o <= tx_start;
  tx_data_o  <= tx_data;
  done_o     <= done_pulse;

  busy_o <= '0' when st = IDLE else '1';

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      tx_start   <= '0';
      done_pulse <= '0';

      -- edge detect
      start_p <= start_i and (not start_d);
      start_d <= start_i;

      done_p  <= tx_done_i and (not done_d);
      done_d  <= tx_done_i;

      if rstn_i = '0' then
        st <= IDLE;
        idx <= (others => '0');
        data_reg <= (others => '0');
        tx_data <= (others => '0');
        start_d <= '0'; start_p <= '0';
        done_d  <= '0'; done_p  <= '0';
        seq <= (others => '0');
        gap_cnt <= (others => '0');
        chk_acc <= (others => '0');

      else
        if pause_i = '1' then
          null; -- freeze everything

        else
          case st is
            when IDLE =>
              idx <= (others => '0');
              gap_cnt <= (others => '0');
              if start_p = '1' then
                st <= H0_WAITIDLE;
              end if;

            -- ===== FF FF =====
            when H0_WAITIDLE =>
              if tx_busy_i = '0' then tx_data <= x"FF"; st <= H0_FIRE; end if;
            when H0_FIRE =>
              tx_start <= '1'; st <= H0_WAITDONE;
            when H0_WAITDONE =>
              if done_p='1' then st <= H1_WAITIDLE; end if;

            when H1_WAITIDLE =>
              if tx_busy_i = '0' then tx_data <= x"FF"; st <= H1_FIRE; end if;
            when H1_FIRE =>
              tx_start <= '1'; st <= H1_WAITDONE;
            when H1_WAITDONE =>
              if done_p='1' then st <= LEN0_WAITIDLE; end if;

            -- ===== LEN (LE) =====
            when LEN0_WAITIDLE =>
              if tx_busy_i='0' then tx_data <= LEN0; st <= LEN0_FIRE; end if;
            when LEN0_FIRE =>
              tx_start <= '1'; st <= LEN0_WAITDONE;
            when LEN0_WAITDONE =>
              if done_p='1' then st <= LEN1_WAITIDLE; end if;

            when LEN1_WAITIDLE =>
              if tx_busy_i='0' then tx_data <= LEN1; st <= LEN1_FIRE; end if;
            when LEN1_FIRE =>
              tx_start <= '1'; st <= LEN1_WAITDONE;
            when LEN1_WAITDONE =>
              if done_p='1' then st <= SEQ_WAITIDLE; end if;

            -- ===== SEQ =====
            when SEQ_WAITIDLE =>
              if tx_busy_i='0' then tx_data <= std_logic_vector(seq); st <= SEQ_FIRE; end if;
            when SEQ_FIRE =>
              tx_start <= '1'; st <= SEQ_WAITDONE;
            when SEQ_WAITDONE =>
              if done_p='1' then
                idx <= (others => '0');
                chk_acc <= (others => '0'); -- reset checksum for new payload
                st <= PAY_SET_ADDR;
              end if;

            -- ===== PAYLOAD (sync BRAM) =====
            when PAY_SET_ADDR =>
              st <= PAY_WAITDATA;

            when PAY_WAITDATA =>
              st <= PAY_LATCH;

            when PAY_LATCH =>
              data_reg <= b_rdata_i;
              st <= PAY_WAITIDLE;

            when PAY_WAITIDLE =>
              if tx_busy_i='0' then
                tx_data <= data_reg;
                st <= PAY_FIRE;
              end if;

            when PAY_FIRE =>
              tx_start <= '1';
              st <= PAY_WAITDONE;

            when PAY_WAITDONE =>
              if done_p='1' then
                -- update checksum AFTER byte is actually sent
                chk_acc <= chk_acc + unsigned(data_reg);
                st <= PAY_ADV;
              end if;

            when PAY_ADV =>
              if idx = U(DEPTH-1, PTR_W) then
                st <= CHK_WAITIDLE;
              else
                idx <= idx + 1;
                st <= PAY_SET_ADDR;
              end if;

            -- ===== CHECKSUM (1 byte) =====
            when CHK_WAITIDLE =>
              if tx_busy_i='0' then
                tx_data <= std_logic_vector(chk_acc);
                st <= CHK_FIRE;
              end if;

            when CHK_FIRE =>
              tx_start <= '1';
              st <= CHK_WAITDONE;

            when CHK_WAITDONE =>
              if done_p='1' then
                st <= FINISH;
              end if;

            -- ===== FINISH + GAP =====
            when FINISH =>
              done_pulse <= '1';
              seq <= seq + 1;

              if continuous_i='1' then
                gap_cnt <= (others => '0');
                st <= GAP_WAIT;
              else
                if start_i='0' then st <= IDLE; end if;
              end if;

            when GAP_WAIT =>
              if gap_cnt = to_unsigned(GAP_CYCLES-1, GAP_W) then
                st <= H0_WAITIDLE;
              else
                gap_cnt <= gap_cnt + 1;
              end if;

          end case;
        end if;
      end if;
    end if;
  end process;

end architecture;
