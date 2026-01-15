library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bram_copy is
  generic (
    DEPTH : natural := 400
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;

    start_i : in  std_logic;   -- LEVEL start

    -- BRAM_A read (sync 1-cycle)
    a_raddr_o : out unsigned(8 downto 0);
    a_rdata_i : in  std_logic_vector(7 downto 0);

    -- BRAM_B write
    b_waddr_o : out unsigned(8 downto 0);
    b_wdata_o : out std_logic_vector(7 downto 0);
    b_we_o    : out std_logic;

    done_o    : out std_logic; -- LEVEL done
    busy_o    : out std_logic
  );
end entity;

architecture rtl of bram_copy is
  constant PTR_W : natural := 9;

  type st_t is (IDLE, SET, WAIT_RD, WRITE, DONE);
  signal st : st_t := IDLE;

  signal idx : unsigned(PTR_W-1 downto 0) := (others => '0');
begin
  a_raddr_o <= idx;
  b_waddr_o <= idx;
  b_wdata_o <= a_rdata_i;

  busy_o <= '1' when st /= IDLE else '0';

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      b_we_o <= '0';

      if rstn_i = '0' then
        st     <= IDLE;
        idx    <= (others => '0');
        done_o <= '0';

      else
        case st is
          when IDLE =>
            done_o <= '0';
            idx    <= (others => '0');
            if start_i = '1' then
              st <= SET;
            end if;

          when SET =>
            st <= WAIT_RD;

          when WAIT_RD =>
            st <= WRITE;

          when WRITE =>
            b_we_o <= '1';
            if idx = to_unsigned(DEPTH-1, PTR_W) then
              st <= DONE;
            else
              idx <= idx + 1;
              st <= SET;
            end if;

          when DONE =>
            done_o <= '1'; -- stay high
            if start_i = '0' then
              st <= IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;
end architecture;
