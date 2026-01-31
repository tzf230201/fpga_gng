library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng is
  generic (
    -- keep generics you already map from top
    MAX_NODES  : natural := 40;
    DATA_WORDS : natural := 100;
    INIT_X0    : integer := 200;
    INIT_Y0    : integer := 200;
    INIT_X1    : integer := 800;
    INIT_Y1    : integer := 800;

    -- debug timing
    CLOCK_HZ       : natural := 27_000_000;
    DBG_DELAY_MS   : natural := 100;
    DBG_NUM_STATES : natural := 8
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;
    start_i : in  std_logic;

    -- dataset (unused in this debug-only gng)
    data_raddr_o : out unsigned(6 downto 0);
    data_rdata_i : in  std_logic_vector(31 downto 0);

    -- status
    gng_done_o : out std_logic;
    gng_busy_o : out std_logic;

    -- UART TX handshake (uart_tx instance stays in TOP)
    tx_busy_i  : in  std_logic;
    tx_done_i  : in  std_logic;
    tx_start_o : out std_logic;
    tx_data_o  : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of gng is

  constant DELAY_TICKS : natural := (CLOCK_HZ / 1000) * DBG_DELAY_MS;

  -- debug packet: [0xA5][state_id]
  constant DBG_HDR : std_logic_vector(7 downto 0) := x"A5";
  constant DBG_END : std_logic_vector(7 downto 0) := x"FF";

  type sm_t is (IDLE, DELAY, SEND_BYTE, WAIT_DONE, ADVANCE, FINISH);
  signal sm : sm_t := IDLE;

  signal run       : std_logic := '0';
  signal done_p    : std_logic := '0';

  signal st_id     : natural range 0 to DBG_NUM_STATES-1 := 0;

  -- delay counter
  signal delay_cnt : integer range 0 to integer(DELAY_TICKS) := 0;

  -- 0 = send header, 1 = send payload
  signal send_idx  : std_logic := '0';

  -- end-mode: when '1', payload becomes 0xFF instead of state_id
  signal end_mode  : std_logic := '0';

  -- for robustness (if tx_done_i pulse is missed)
  signal tx_inflight : std_logic := '0';

  function to_u8(n : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(n mod 256, 8));
  end function;

begin

  -- dataset is unused in this debug version
  data_raddr_o <= (others => '0');

  gng_busy_o <= run;
  gng_done_o <= done_p;

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        sm         <= IDLE;
        run        <= '0';
        done_p     <= '0';
        st_id      <= 0;
        delay_cnt  <= 0;
        send_idx   <= '0';
        end_mode   <= '0';
        tx_inflight<= '0';

        tx_start_o <= '0';
        tx_data_o  <= (others=>'0');

      else
        -- defaults
        tx_start_o  <= '0';
        done_p      <= '0';

        -- if we are waiting for tx completion, clear inflight when tx finishes
        if tx_inflight = '1' then
          if (tx_done_i = '1') or (tx_busy_i = '0') then
            tx_inflight <= '0';
          end if;
        end if;

        case sm is
          ------------------------------------------------------------
          when IDLE =>
            -- wait first start, then run forever (loop)
            run      <= '0';
            end_mode <= '0';
            send_idx <= '0';
            tx_inflight <= '0';

            if start_i = '1' then
              run       <= '1';
              st_id     <= 0;
              send_idx  <= '0';
              end_mode  <= '0';
              delay_cnt <= integer(DELAY_TICKS);
              sm        <= DELAY;
            end if;

          ------------------------------------------------------------
          when DELAY =>
            -- wait DBG_DELAY_MS before printing next state
            if delay_cnt <= 0 then
              send_idx <= '0';
              sm       <= SEND_BYTE;
            else
              delay_cnt <= delay_cnt - 1;
            end if;

          ------------------------------------------------------------
          when SEND_BYTE =>
            -- only start TX when uart_tx is idle and not inflight
            if (tx_busy_i = '0') and (tx_inflight = '0') then
              tx_start_o  <= '1';
              tx_inflight <= '1';

              if send_idx = '0' then
                tx_data_o <= DBG_HDR;
              else
                if end_mode = '1' then
                  tx_data_o <= DBG_END; -- 0xFF
                else
                  tx_data_o <= to_u8(st_id);
                end if;
              end if;

              sm <= WAIT_DONE;
            end if;

          ------------------------------------------------------------
          when WAIT_DONE =>
            -- robust completion detection:
            -- accept tx_done pulse OR tx_busy becomes 0 after inflight cleared
            if (tx_done_i = '1') or (tx_inflight = '0') then
              if send_idx = '0' then
                -- header sent, now send payload
                send_idx <= '1';
                sm       <= SEND_BYTE;
              else
                -- payload sent
                sm <= ADVANCE;
              end if;
            end if;

          ------------------------------------------------------------
          when ADVANCE =>
            -- after printing one state, move to next (with delay again)
            if end_mode = '1' then
              -- end packet (A5 FF) just completed: pulse done each loop
              done_p   <= '1';

              -- LOOP FOREVER: restart to state 0 (no need start_i again)
              end_mode  <= '0';
              st_id     <= 0;
              send_idx  <= '0';
              delay_cnt <= integer(DELAY_TICKS);
              sm        <= DELAY;

            else
              if st_id = DBG_NUM_STATES-1 then
                -- go to finish: send [A5][FF]
                end_mode  <= '1';
                send_idx  <= '0';
                delay_cnt <= integer(DELAY_TICKS);
                sm        <= FINISH;
              else
                st_id     <= st_id + 1;
                send_idx  <= '0';
                delay_cnt <= integer(DELAY_TICKS);
                sm        <= DELAY;
              end if;
            end if;

          ------------------------------------------------------------
          when FINISH =>
            -- optional delay before sending end marker
            if delay_cnt <= 0 then
              send_idx <= '0';
              sm       <= SEND_BYTE; -- will send HDR then 0xFF
            else
              delay_cnt <= delay_cnt - 1;
            end if;

          when others =>
            sm <= IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture;
