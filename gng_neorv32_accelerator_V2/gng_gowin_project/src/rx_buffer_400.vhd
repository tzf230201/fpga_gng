library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rx_copy_send_400 is
  generic (
    DEPTH : natural := 400
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;  -- active-low

    -- dari UART RX
    rx_valid_i : in  std_logic;                  -- pulse 1 clk saat byte valid
    rx_data_i  : in  std_logic_vector(7 downto 0);

    -- dari UART TX
    tx_busy_i  : in  std_logic;
    tx_done_i  : in  std_logic;                  -- pulse 1 clk saat 1 byte selesai terkirim

    -- ke UART TX
    tx_start_o : out std_logic;                  -- pulse 1 clk untuk mulai kirim
    tx_data_o  : out std_logic_vector(7 downto 0);

    -- debug (opsional)
    filling_o  : out std_logic;
    copying_o  : out std_logic;
    sending_o  : out std_logic
  );
end entity;

architecture rtl of rx_copy_send_400 is
  constant PTR_W : natural := 9; -- cukup untuk 0..511

  type mem_t is array (0 to DEPTH-1) of std_logic_vector(7 downto 0);
  signal rx_bram : mem_t;  -- BRAM A
  signal tx_bram : mem_t;  -- BRAM B (hasil copy)

  type mode_t is (FILL, COPY, SEND);
  signal mode : mode_t := FILL;

  signal wr_idx : unsigned(PTR_W-1 downto 0) := (others => '0');
  signal cp_idx : unsigned(PTR_W-1 downto 0) := (others => '0');
  signal rd_idx : unsigned(PTR_W-1 downto 0) := (others => '0');

  signal fill_count : unsigned(PTR_W-1 downto 0) := (others => '0'); -- 0..DEPTH-1
  signal send_count : unsigned(PTR_W-1 downto 0) := (others => '0'); -- 0..DEPTH-1

  signal start_pending : std_logic := '0';
  signal tx_start      : std_logic := '0';

  function U(n : natural; w : natural) return unsigned is
  begin
    return to_unsigned(n, w);
  end function;

begin
  tx_start_o <= tx_start;

  -- TX selalu baca dari BRAM_B (hasil copy)
  tx_data_o <= tx_bram(to_integer(rd_idx));

  filling_o <= '1' when mode = FILL else '0';
  copying_o <= '1' when mode = COPY else '0';
  sending_o <= '1' when mode = SEND else '0';

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      tx_start <= '0'; -- default

      if rstn_i = '0' then
        mode          <= FILL;
        wr_idx        <= (others => '0');
        cp_idx        <= (others => '0');
        rd_idx        <= (others => '0');
        fill_count    <= (others => '0');
        send_count    <= (others => '0');
        start_pending <= '0';

      else
        case mode is
          -- =========================
          -- 1) FILL: isi BRAM_A 400 byte
          -- =========================
          when FILL =>
            if rx_valid_i = '1' then
              rx_bram(to_integer(wr_idx)) <= rx_data_i;

              if fill_count = U(DEPTH-1, PTR_W) then
                -- sudah tulis byte terakhir -> lanjut COPY
                mode       <= COPY;
                cp_idx     <= (others => '0');

                -- reset pointer fill untuk batch berikutnya
                wr_idx     <= (others => '0');
                fill_count <= (others => '0');
              else
                wr_idx     <= wr_idx + 1;
                fill_count <= fill_count + 1;
              end if;
            end if;

          -- =========================
          -- 2) COPY: copy BRAM_A -> BRAM_B
          -- =========================
          when COPY =>
            tx_bram(to_integer(cp_idx)) <= rx_bram(to_integer(cp_idx));

            if cp_idx = U(DEPTH-1, PTR_W) then
              -- selesai copy -> mulai SEND
              mode          <= SEND;
              rd_idx        <= (others => '0');
              send_count    <= (others => '0');
              start_pending <= '1';
            else
              cp_idx <= cp_idx + 1;
            end if;

          -- =========================
          -- 3) SEND: kirim 400 byte dari BRAM_B satu-per-satu
          --    (advance pakai tx_done biar akurat)
          -- =========================
          when SEND =>
            -- start jika pending dan TX idle
            if (start_pending = '1') and (tx_busy_i = '0') then
              tx_start      <= '1';
              start_pending <= '0';
            end if;

            -- setelah 1 byte benar-benar selesai (tx_done), maju
            if tx_done_i = '1' then
              if send_count = U(DEPTH-1, PTR_W) then
                -- selesai batch -> balik FILL
                mode          <= FILL;
                rd_idx        <= (others => '0');
                send_count    <= (others => '0');
                start_pending <= '0';
              else
                send_count    <= send_count + 1;
                rd_idx        <= rd_idx + 1;
                start_pending <= '1';
              end if;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture;
