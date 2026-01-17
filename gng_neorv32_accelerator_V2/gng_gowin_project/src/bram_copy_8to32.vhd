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
    start_i : in std_logic;

    -- read from BRAM_A (byte)
    a_raddr_o : out unsigned(8 downto 0);
    a_rdata_i : in  std_logic_vector(7 downto 0);

    -- write to BRAM_C (word32)
    c_we_o    : out std_logic;
    c_waddr_o : out unsigned(6 downto 0);
    c_wdata_o : out std_logic_vector(31 downto 0);

    done_o : out std_logic;
    busy_o : out std_logic
  );
end entity;

architecture rtl of bram_copy_8to32 is
  constant WORDS : natural := DEPTH_BYTES/4;

  type st_t is (
    IDLE,
    RD0_SET, RD0_WAIT, RD0_LATCH,
    RD1_SET, RD1_WAIT, RD1_LATCH,
    RD2_SET, RD2_WAIT, RD2_LATCH,
    RD3_SET, RD3_WAIT, RD3_LATCH,
    WR_WORD,
    ADV,
    FINISH
  );
  signal st : st_t := IDLE;

  signal widx : unsigned(6 downto 0) := (others => '0'); -- 0..99
  signal addr_byte : unsigned(8 downto 0) := (others => '0');

  signal b0, b1, b2, b3 : std_logic_vector(7 downto 0) := (others => '0');

  signal c_we : std_logic := '0';
  signal done_p : std_logic := '0';

  -- start edge detect
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

begin
  busy_o <= '0' when st = IDLE else '1';
  done_o <= done_p;

  c_we_o <= c_we;

  a_raddr_o <= addr_byte;

  process(clk_i)
    variable base : unsigned(8 downto 0);
  begin
    if rising_edge(clk_i) then
      c_we   <= '0';
      done_p <= '0';

      start_p <= start_i and (not start_d);
      start_d <= start_i;

      if rstn_i = '0' then
        st <= IDLE;
        widx <= (others => '0');
        addr_byte <= (others => '0');
        b0 <= (others => '0'); b1 <= (others => '0'); b2 <= (others => '0'); b3 <= (others => '0');
        c_waddr_o <= (others => '0');
        c_wdata_o <= (others => '0');

      else
        case st is
          when IDLE =>
            widx <= (others => '0');
            if start_p = '1' then
              st <= RD0_SET;
            end if;

          when RD0_SET =>
            base := resize(widx, 9) sll 2; -- widx*4
            addr_byte <= base + 0;
            st <= RD0_WAIT;
          when RD0_WAIT =>
            st <= RD0_LATCH;
          when RD0_LATCH =>
            b0 <= a_rdata_i;
            st <= RD1_SET;

          when RD1_SET =>
            base := resize(widx, 9) sll 2;
            addr_byte <= base + 1;
            st <= RD1_WAIT;
          when RD1_WAIT =>
            st <= RD1_LATCH;
          when RD1_LATCH =>
            b1 <= a_rdata_i;
            st <= RD2_SET;

          when RD2_SET =>
            base := resize(widx, 9) sll 2;
            addr_byte <= base + 2;
            st <= RD2_WAIT;
          when RD2_WAIT =>
            st <= RD2_LATCH;
          when RD2_LATCH =>
            b2 <= a_rdata_i;
            st <= RD3_SET;

          when RD3_SET =>
            base := resize(widx, 9) sll 2;
            addr_byte <= base + 3;
            st <= RD3_WAIT;
          when RD3_WAIT =>
            st <= RD3_LATCH;
          when RD3_LATCH =>
            b3 <= a_rdata_i;
            st <= WR_WORD;

          when WR_WORD =>
            -- store as [31:24]=yH(b3), [23:16]=yL(b2), [15:8]=xH(b1), [7:0]=xL(b0)
            c_we    <= '1';
            c_waddr_o <= widx;
            c_wdata_o <= b3 & b2 & b1 & b0;
            st <= ADV;

          when ADV =>
            if widx = to_unsigned(WORDS-1, widx'length) then
              st <= FINISH;
            else
              widx <= widx + 1;
              st <= RD0_SET;
            end if;

          when FINISH =>
            done_p <= '1';
            st <= IDLE;

          when others =>
            st <= IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture;
