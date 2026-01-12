library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rx_buffer_400 is
  generic (
    DEPTH : natural := 400
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;  -- active-low reset

    -- dari UART RX
    rx_valid_i : in  std_logic;                  -- pulse 1 clk saat byte masuk
    rx_data_i  : in  std_logic_vector(7 downto 0);

    -- status dari UART TX
    tx_busy_i  : in  std_logic;
    tx_done_i  : in  std_logic;                  -- pulse 1 clk saat selesai 1 byte

    -- ke UART TX
    tx_start_o : out std_logic;                  -- pulse 1 clk untuk mulai kirim
    tx_data_o  : out std_logic_vector(7 downto 0);

    sending_o  : out std_logic
  );
end entity;

architecture rtl of rx_buffer_400 is
  constant PTR_W : natural := 9; -- cukup untuk 0..511

  type mem_t is array (0 to DEPTH-1) of std_logic_vector(7 downto 0);
  signal mem : mem_t;

  type mode_t is (FILL, SEND);
  signal mode : mode_t := FILL;

  signal wr_idx : unsigned(PTR_W-1 downto 0) := (others => '0');
  signal rd_idx : unsigned(PTR_W-1 downto 0) := (others => '0');

  signal fill_count : unsigned(PTR_W-1 downto 0) := (others => '0'); -- 0..DEPTH
  signal send_count : unsigned(PTR_W-1 downto 0) := (others => '0'); -- 0..DEPTH

  signal start_pending : std_logic := '0';
  signal tx_start      : std_logic := '0';

  function U(n : natural; w : natural) return unsigned is
  begin
    return to_unsigned(n, w);
  end function;

begin
  tx_start_o <= tx_start;
  tx_data_o  <= mem(to_integer(rd_idx));
  sending_o  <= '1' when mode = SEND else '0';

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      tx_start <= '0'; -- default

      if rstn_i = '0' then
        mode          <= FILL;
        wr_idx        <= (others => '0');
        rd_idx        <= (others => '0');
        fill_count    <= (others => '0');
        send_count    <= (others => '0');
        start_pending <= '0';

      else
        case mode is
          when FILL =>
            -- terima sampai DEPTH byte
            if rx_valid_i = '1' then
              mem(to_integer(wr_idx)) <= rx_data_i;

              fill_count <= fill_count + 1;

              if fill_count < U(DEPTH-1, PTR_W) then
                wr_idx <= wr_idx + 1;
              end if;

              -- baru saja masuk byte terakhir
              if fill_count = U(DEPTH-1, PTR_W) then
                mode          <= SEND;
                rd_idx        <= (others => '0');
                send_count    <= (others => '0');
                start_pending <= '1';   -- arm kirim byte pertama

                -- siap batch berikutnya setelah selesai SEND
                wr_idx     <= (others => '0');
                fill_count <= (others => '0');
              end if;
            end if;

          when SEND =>
            -- kalau ada start_pending dan TX sedang idle -> start 1 byte
            if (start_pending = '1') and (tx_busy_i = '0') then
              tx_start      <= '1';    -- 1 clock pulse
              start_pending <= '0';
            end if;

            -- setelah TX selesai 1 byte (tx_done), maju ke byte berikutnya
            if tx_done_i = '1' then
              if send_count = U(DEPTH-1, PTR_W) then
                -- selesai kirim 400 byte -> balik fill
                mode          <= FILL;
                rd_idx        <= (others => '0');
                send_count    <= (others => '0');
                start_pending <= '0';
              else
                send_count    <= send_count + 1;
                rd_idx        <= rd_idx + 1;
                start_pending <= '1';  -- arm kirim byte berikutnya
              end if;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture;
