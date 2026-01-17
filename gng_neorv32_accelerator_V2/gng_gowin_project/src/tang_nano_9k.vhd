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
  constant DEPTH   : natural := 400;
  constant WORDS_C : natural := DEPTH/4; -- 100 word32

  ---------------------------------------------------------------------------
  -- adjustable scheduler
  ---------------------------------------------------------------------------
  constant SHIFT_EVERY_PKTS : natural := 5;   -- shift tiap N packet
  constant TRAIN_EVERY_PKTS : natural := 10;  -- 1 train step tiap N packet (ubah bebas)

  ---------------------------------------------------------------------------
  -- UART RX
  ---------------------------------------------------------------------------
  signal rx_data  : std_logic_vector(7 downto 0);
  signal rx_valid : std_logic;
  signal rx_busy  : std_logic;
  signal rx_err   : std_logic;

  ---------------------------------------------------------------------------
  -- UART TX
  ---------------------------------------------------------------------------
  signal tx_start : std_logic;
  signal tx_data  : std_logic_vector(7 downto 0);
  signal tx_busy  : std_logic;
  signal tx_done  : std_logic;
  signal txd      : std_logic;

  ---------------------------------------------------------------------------
  -- BRAM_A (RX store) byte
  ---------------------------------------------------------------------------
  type mem_a_t is array (0 to DEPTH-1) of std_logic_vector(7 downto 0);
  signal mem_a : mem_a_t;

  signal a_we    : std_logic;
  signal a_waddr : unsigned(8 downto 0);
  signal a_wdata : std_logic_vector(7 downto 0);

  signal a_raddr : unsigned(8 downto 0);
  signal a_rdata : std_logic_vector(7 downto 0);

  signal full_p     : std_logic;
  signal locked     : std_logic;
  signal full_p_dly : std_logic := '0';

  ---------------------------------------------------------------------------
  -- BRAM_C (word32): [15:0]=X int16, [31:16]=Y int16
  ---------------------------------------------------------------------------
  type mem_c_t is array (0 to WORDS_C-1) of std_logic_vector(31 downto 0);
  signal mem_c : mem_c_t;

  -- COPY write
  signal c_we_copy    : std_logic;
  signal c_waddr_copy : unsigned(6 downto 0);
  signal c_wdata_copy : std_logic_vector(31 downto 0);

  -- SHIFT write (wins)
  signal c_we_shift    : std_logic;
  signal c_waddr_shift : unsigned(6 downto 0);
  signal c_wdata_shift : std_logic_vector(31 downto 0);

  -- write mux -> mem_c
  signal c_we_mem    : std_logic;
  signal c_waddr_mem : unsigned(6 downto 0);
  signal c_wdata_mem : std_logic_vector(31 downto 0);

  -- read mux -> mem_c (GNG > SHIFT > SEND)
  signal c_raddr_mem   : unsigned(6 downto 0);
  signal c_raddr_send  : unsigned(6 downto 0);
  signal c_raddr_shift : unsigned(6 downto 0);
  signal c_raddr_gng   : unsigned(6 downto 0);

  signal c_rdata : std_logic_vector(31 downto 0);

  ---------------------------------------------------------------------------
  -- flags
  ---------------------------------------------------------------------------
  signal copying   : std_logic;
  signal copy_done : std_logic;

  signal sending     : std_logic;
  signal send_done_p : std_logic;

  signal shifting   : std_logic;
  signal shift_done : std_logic;

  signal gng_busy  : std_logic;
  signal gng_done  : std_logic;
  signal gng_term  : std_logic;

  ---------------------------------------------------------------------------
  -- debug latches
  ---------------------------------------------------------------------------
  signal full_rx_store : std_logic := '0';
  signal data_ready_p  : std_logic := '0';

  ---------------------------------------------------------------------------
  -- scheduler FSM
  ---------------------------------------------------------------------------
  type sm_t is (
    WAIT_DATA,
    DO_GNG_INIT, WAIT_GNG_INIT,
    STREAMING,
    DO_GNG_STEP, WAIT_GNG_STEP,
    DO_SHIFT, WAIT_SHIFT
  );
  signal sm : sm_t := WAIT_DATA;

  signal shift_cnt : unsigned(7 downto 0) := (others => '0');
  signal train_cnt : unsigned(7 downto 0) := (others => '0');

  signal shift_start_pulse : std_logic := '0';
  signal gng_init_pulse    : std_logic := '0';
  signal gng_step_pulse    : std_logic := '0';

  signal pause_send : std_logic;

begin

  ---------------------------------------------------------------------------
  -- debug latch: remember full
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        full_rx_store <= '0';
      elsif full_p = '1' then
        full_rx_store <= '1';
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- full_p delayed 1 cycle
  ---------------------------------------------------------------------------
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

  ---------------------------------------------------------------------------
  -- BRAM_A (sync write + sync read)
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if a_we = '1' then
        mem_a(to_integer(a_waddr)) <= a_wdata;
      end if;
      a_rdata <= mem_a(to_integer(a_raddr));
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- BRAM_C mux
  ---------------------------------------------------------------------------
  c_raddr_mem <= c_raddr_gng   when (gng_busy  = '1') else
                 c_raddr_shift when (shifting = '1') else
                 c_raddr_send;

  c_we_mem    <= c_we_shift or c_we_copy;
  c_waddr_mem <= c_waddr_shift when (c_we_shift = '1') else c_waddr_copy;
  c_wdata_mem <= c_wdata_shift when (c_we_shift = '1') else c_wdata_copy;

  ---------------------------------------------------------------------------
  -- BRAM_C (sync write + sync read)
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if c_we_mem = '1' then
        mem_c(to_integer(c_waddr_mem)) <= c_wdata_mem;
      end if;
      c_rdata <= mem_c(to_integer(c_raddr_mem));
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- UART RX
  ---------------------------------------------------------------------------
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

  ---------------------------------------------------------------------------
  -- RX STORE
  ---------------------------------------------------------------------------
  u_store : entity work.rx_store_ext
    generic map ( DEPTH => DEPTH )
    port map (
      clk_i        => clk_i,
      rstn_i       => rstn_i,
      rx_valid_i   => rx_valid,
      rx_data_i    => rx_data,
      hold_i       => copying, -- hold during copy
      clear_i      => '0',
      full_o       => full_p,

      mem_we_o     => a_we,
      mem_waddr_o  => a_waddr,
      mem_wdata_o  => a_wdata,

      mem_raddr_i  => a_raddr,
      mem_rdata_i  => a_rdata,

      rdata_o      => open,
      locked_o     => locked
    );

  ---------------------------------------------------------------------------
  -- COPY 8-bit -> 32-bit (A -> C)
  ---------------------------------------------------------------------------
  u_copy_8to32 : entity work.bram_copy_8to32
    generic map (
      DEPTH_BYTES => DEPTH
    )
    port map (
      clk_i     => clk_i,
      rstn_i    => rstn_i,
      start_i   => full_p_dly,

      a_raddr_o => a_raddr,
      a_rdata_i => a_rdata,

      c_we_o    => c_we_copy,
      c_waddr_o => c_waddr_copy,
      c_wdata_o => c_wdata_copy,

      done_o    => copy_done,
      busy_o    => copying
    );

  ---------------------------------------------------------------------------
  -- data_ready latch
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        data_ready_p <= '0';
      elsif copy_done = '1' then
        data_ready_p <= '1';
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- pause sender during copy/gng/shift or non-streaming states
  ---------------------------------------------------------------------------
  pause_send <= copying or gng_busy or shifting or
                '1' when (sm /= STREAMING) else '0';

  ---------------------------------------------------------------------------
  -- Scheduler FSM
  ---------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        sm <= WAIT_DATA;
        shift_cnt <= (others => '0');
        train_cnt <= (others => '0');
        shift_start_pulse <= '0';
        gng_init_pulse <= '0';
        gng_step_pulse <= '0';
      else
        shift_start_pulse <= '0';
        gng_init_pulse <= '0';
        gng_step_pulse <= '0';

        case sm is
          when WAIT_DATA =>
            shift_cnt <= (others => '0');
            train_cnt <= (others => '0');
            if data_ready_p = '1' then
              sm <= DO_GNG_INIT;
            end if;

          when DO_GNG_INIT =>
            gng_init_pulse <= '1';  -- 1 cycle
            sm <= WAIT_GNG_INIT;

          when WAIT_GNG_INIT =>
            if gng_done = '1' then
              sm <= STREAMING;
            end if;

          when STREAMING =>
            if send_done_p = '1' then
              -- SHIFT schedule first
              if SHIFT_EVERY_PKTS /= 0 and shift_cnt = to_unsigned(SHIFT_EVERY_PKTS-1, shift_cnt'length) then
                shift_cnt <= (others => '0');
                sm <= DO_SHIFT;
              else
                if SHIFT_EVERY_PKTS /= 0 then
                  shift_cnt <= shift_cnt + 1;
                end if;

                -- TRAIN schedule (skip if terminated)
                if (TRAIN_EVERY_PKTS /= 0) and (gng_term = '0') then
                  if train_cnt = to_unsigned(TRAIN_EVERY_PKTS-1, train_cnt'length) then
                    train_cnt <= (others => '0');
                    sm <= DO_GNG_STEP;
                  else
                    train_cnt <= train_cnt + 1;
                  end if;
                end if;
              end if;
            end if;

          when DO_GNG_STEP =>
            gng_step_pulse <= '1';
            sm <= WAIT_GNG_STEP;

          when WAIT_GNG_STEP =>
            if gng_done = '1' then
              sm <= STREAMING;
            end if;

          when DO_SHIFT =>
            shift_start_pulse <= '1';
            sm <= WAIT_SHIFT;

          when WAIT_SHIFT =>
            if shift_done = '1' then
              sm <= STREAMING;
            end if;

          when others =>
            sm <= WAIT_DATA;
        end case;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- GNG (init + 1-step)
  ---------------------------------------------------------------------------
  u_gng : entity work.gng
    generic map (
      WORDS      => WORDS_C,
      MAX_NODES  => 32,
      LEARN_SHIFT=> 4,
      MAX_STEPS  => 10000
    )
    port map (
      clk_i     => clk_i,
      rstn_i    => rstn_i,

      init_i    => gng_init_pulse,
      step_i    => gng_step_pulse,

      c_raddr_o => c_raddr_gng,
      c_rdata_i => c_rdata,

      done_o    => gng_done,
      busy_o    => gng_busy,
      term_o    => gng_term
    );

  ---------------------------------------------------------------------------
  -- SHIFT word32 in BRAM_C
  ---------------------------------------------------------------------------
  u_shift32 : entity work.bram_shift_word32_xy
    generic map (
      WORDS   => WORDS_C,
      STEP_X  => 10,
      STEP_Y  => 0,
      LIMIT_X => 300,
      LIMIT_Y => 0
    )
    port map (
      clk_i         => clk_i,
      rstn_i        => rstn_i,
      shift_start_i => shift_start_pulse,

      c_raddr_o     => c_raddr_shift,
      c_rdata_i     => c_rdata,

      c_we_o        => c_we_shift,
      c_waddr_o     => c_waddr_shift,
      c_wdata_o     => c_wdata_shift,

      shift_done_o  => shift_done,
      shifting_o    => shifting
    );

  ---------------------------------------------------------------------------
  -- SEND word32 (C -> UART)
  ---------------------------------------------------------------------------
  u_send32 : entity work.bram_send_word32_sumchk
    generic map (
      WORDS     => WORDS_C,
      CLOCK_HZ  => CLOCK_FREQUENCY,
      STREAM_HZ => 50
    )
    port map (
      clk_i        => clk_i,
      rstn_i       => rstn_i,
      start_i      => '1',
      continuous_i => '1',
      pause_i      => pause_send,

      c_raddr_o    => c_raddr_send,
      c_rdata_i    => c_rdata,

      tx_busy_i    => tx_busy,
      tx_done_i    => tx_done,
      tx_start_o   => tx_start,
      tx_data_o    => tx_data,

      done_o       => send_done_p,
      busy_o       => sending
    );

  ---------------------------------------------------------------------------
  -- UART TX
  ---------------------------------------------------------------------------
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

  ---------------------------------------------------------------------------
  -- LEDs active-low
  -- 0=sending, 1=copying, 2=locked, 3=full_seen, 4=shifting, 5=data_ready
  ---------------------------------------------------------------------------
  gpio_o <= (
    0 => std_ulogic(not sending),
    1 => std_ulogic(not copying),
    2 => std_ulogic(not locked),
    3 => std_ulogic(not full_rx_store),
    4 => std_ulogic(not shifting),
    5 => std_ulogic(not data_ready_p)
  );

end architecture;
