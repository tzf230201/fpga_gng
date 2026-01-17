library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity train_one_step_stub is
  generic (
    WORDS : natural := 100
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in  std_logic;
    busy_o  : out std_logic;
    done_o  : out std_logic;

    pt_idx_i  : in  unsigned(6 downto 0);
    c_raddr_o : out unsigned(6 downto 0);
    c_rdata_i : in  std_logic_vector(31 downto 0);

    pt_x_o : out signed(15 downto 0);
    pt_y_o : out signed(15 downto 0)
  );
end entity;

architecture rtl of train_one_step_stub is
  type st_t is (IDLE, RD_WAIT, LATCH, FINISH);
  signal st : st_t := IDLE;

  signal done_p : std_logic := '0';
begin

  c_raddr_o <= pt_idx_i;

  busy_o <= '0' when st = IDLE else '1';
  done_o <= done_p;

  process(clk_i)
    variable xs : signed(15 downto 0);
    variable ys : signed(15 downto 0);
  begin
    if rising_edge(clk_i) then
      done_p <= '0';

      if rstn_i = '0' then
        st <= IDLE;
        pt_x_o <= (others => '0');
        pt_y_o <= (others => '0');

      else
        case st is
          when IDLE =>
            if start_i = '1' then
              st <= RD_WAIT; -- because BRAM sync read
            end if;

          when RD_WAIT =>
            st <= LATCH;

          when LATCH =>
            xs := signed(c_rdata_i(15 downto 0));
            ys := signed(c_rdata_i(31 downto 16));
            pt_x_o <= xs;
            pt_y_o <= ys;
            st <= FINISH;

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
