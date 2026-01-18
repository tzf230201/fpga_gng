library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bram_copy_8to32 is
  generic (
    DEPTH_BYTES : natural := 400
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in  std_logic;

    -- read mem_a (sync 1-cycle)
    a_raddr_o : out unsigned(8 downto 0);
    a_rdata_i : in  std_logic_vector(7 downto 0);

    -- write mem_c
    c_we_o    : out std_logic;
    c_waddr_o : out unsigned(6 downto 0);
    c_wdata_o : out std_logic_vector(31 downto 0);

    done_o : out std_logic;
    busy_o : out std_logic
  );
end entity;

architecture rtl of bram_copy_8to32 is
  constant WORDS : natural := DEPTH_BYTES/4;

  type st_t is (IDLE, RD_SET, RD_WAIT, RD_LATCH, WR_WORD, ADV, FINISH);
  signal st : st_t := IDLE;

  signal word_i : unsigned(6 downto 0) := (others => '0'); -- 0..99
  signal byte_k : unsigned(1 downto 0) := (others => '0'); -- 0..3

  signal a_addr : unsigned(8 downto 0) := (others => '0');

  signal b0, b1, b2, b3 : std_logic_vector(7 downto 0) := (others => '0');

begin
  a_raddr_o <= a_addr;

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      c_we_o  <= '0';
      done_o  <= '0';

      if rstn_i = '0' then
        st     <= IDLE;
        word_i <= (others => '0');
        byte_k <= (others => '0');
        a_addr <= (others => '0');
        b0 <= (others => '0'); b1 <= (others => '0'); b2 <= (others => '0'); b3 <= (others => '0');
      else
        case st is
          when IDLE =>
            word_i <= (others => '0');
            byte_k <= (others => '0');
            if start_i = '1' then
              a_addr <= (others => '0');
              st <= RD_SET;
            end if;

          when RD_SET =>
            -- set address for current byte: addr = word_i*4 + byte_k
            a_addr <= resize(word_i, 9) sll 2;
            a_addr <= (resize(word_i, 9) sll 2) + resize(byte_k, 9);
            st <= RD_WAIT;

          when RD_WAIT =>
            st <= RD_LATCH;

          when RD_LATCH =>
            case byte_k is
              when "00" => b0 <= a_rdata_i;
              when "01" => b1 <= a_rdata_i;
              when "10" => b2 <= a_rdata_i;
              when others => b3 <= a_rdata_i;
            end case;

            if byte_k = "11" then
              st <= WR_WORD;
            else
              byte_k <= byte_k + 1;
              st <= RD_SET;
            end if;

          when WR_WORD =>
            c_we_o    <= '1';
            c_waddr_o <= word_i;
            c_wdata_o <= b3 & b2 & b1 & b0; -- payload order: xL xH yL yH in bytes
            st <= ADV;

          when ADV =>
            byte_k <= (others => '0');
            if word_i = to_unsigned(WORDS-1, word_i'length) then
              st <= FINISH;
            else
              word_i <= word_i + 1;
              st <= RD_SET;
            end if;

          when FINISH =>
            done_o <= '1';
            st <= IDLE;

          when others =>
            st <= IDLE;
        end case;
      end if;
    end if;
  end process;

  busy_o <= '0' when st = IDLE else '1';
end architecture;