library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bram_shift_word32_xy is
  generic (
    WORDS   : natural := 100;
    STEP_X  : integer := 10;
    STEP_Y  : integer := 0;
    LIMIT_X : integer := 300;
    LIMIT_Y : integer := 0
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    shift_start_i : in  std_logic;

    c_raddr_o : out unsigned(6 downto 0);
    c_rdata_i : in  std_logic_vector(31 downto 0);

    c_we_o    : out std_logic;
    c_waddr_o : out unsigned(6 downto 0);
    c_wdata_o : out std_logic_vector(31 downto 0);

    shift_done_o : out std_logic;
    shifting_o   : out std_logic
  );
end entity;

architecture rtl of bram_shift_word32_xy is
  type st_t is (IDLE, RD_SET, RD_WAIT, RD_LATCH, WR, ADV, FINISH);
  signal st : st_t := IDLE;

  signal idx : unsigned(6 downto 0) := (others => '0');

  signal c_we : std_logic := '0';
  signal done_p : std_logic := '0';

  -- ping-pong offsets
  signal off_x : integer := 0;
  signal off_y : integer := 0;
  signal dir_x : integer := 1;
  signal dir_y : integer := 1;

  signal delta_x : integer := 0;
  signal delta_y : integer := 0;

  -- start edge detect
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  function sat16(v : integer) return integer is
  begin
    if v > 32767 then return 32767;
    elsif v < -32768 then return -32768;
    else return v;
    end if;
  end function;

begin
  c_raddr_o <= idx;

  c_we_o <= c_we;
  shift_done_o <= done_p;
  shifting_o <= '0' when st = IDLE else '1';

  process(clk_i)
    variable x_i, y_i : integer;
    variable x_n, y_n : integer;

    variable next_off_x : integer;
    variable next_dir_x : integer;
    variable next_off_y : integer;
    variable next_dir_y : integer;

    variable xs : signed(15 downto 0);
    variable ys : signed(15 downto 0);
  begin
    if rising_edge(clk_i) then
      c_we   <= '0';
      done_p <= '0';

      start_p <= shift_start_i and (not start_d);
      start_d <= shift_start_i;

      if rstn_i = '0' then
        st <= IDLE;
        idx <= (others => '0');
        off_x <= 0; off_y <= 0;
        dir_x <= 1; dir_y <= 1;
        delta_x <= 0; delta_y <= 0;
        c_waddr_o <= (others => '0');
        c_wdata_o <= (others => '0');

      else
        case st is
          when IDLE =>
            idx <= (others => '0');
            if start_p = '1' then
              -- compute ping-pong delta X
              next_dir_x := dir_x;
              next_off_x := off_x + dir_x * STEP_X;

              if STEP_X = 0 or LIMIT_X = 0 then
                next_off_x := off_x;
                next_dir_x := dir_x;
              else
                if next_off_x > LIMIT_X then
                  next_off_x := LIMIT_X;
                  next_dir_x := -1;
                elsif next_off_x < -LIMIT_X then
                  next_off_x := -LIMIT_X;
                  next_dir_x := 1;
                end if;
              end if;

              -- compute ping-pong delta Y
              next_dir_y := dir_y;
              next_off_y := off_y + dir_y * STEP_Y;

              if STEP_Y = 0 or LIMIT_Y = 0 then
                next_off_y := off_y;
                next_dir_y := dir_y;
              else
                if next_off_y > LIMIT_Y then
                  next_off_y := LIMIT_Y;
                  next_dir_y := -1;
                elsif next_off_y < -LIMIT_Y then
                  next_off_y := -LIMIT_Y;
                  next_dir_y := 1;
                end if;
              end if;

              delta_x <= next_off_x - off_x;
              delta_y <= next_off_y - off_y;

              off_x <= next_off_x; dir_x <= next_dir_x;
              off_y <= next_off_y; dir_y <= next_dir_y;

              st <= RD_SET;
            end if;

          when RD_SET =>
            st <= RD_WAIT;

          when RD_WAIT =>
            st <= RD_LATCH;

          when RD_LATCH =>
            xs := signed(c_rdata_i(15 downto 0));
            ys := signed(c_rdata_i(31 downto 16));

            x_i := to_integer(xs);
            y_i := to_integer(ys);

            x_n := sat16(x_i + delta_x);
            y_n := sat16(y_i + delta_y);

            c_waddr_o <= idx;
            c_wdata_o <= std_logic_vector(to_signed(y_n, 16)) & std_logic_vector(to_signed(x_n, 16));

            st <= WR;

          when WR =>
            c_we <= '1';
            st <= ADV;

          when ADV =>
            if idx = to_unsigned(WORDS-1, idx'length) then
              st <= FINISH;
            else
              idx <= idx + 1;
              st <= RD_SET;
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
