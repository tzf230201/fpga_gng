library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bram_shift_word32_xy16 is
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

    start_i : in  std_logic;

    -- read mem_c (sync 1-cycle)
    c_raddr_o : out unsigned(6 downto 0);
    c_rdata_i : in  std_logic_vector(31 downto 0);

    -- write mem_c
    c_we_o    : out std_logic;
    c_waddr_o : out unsigned(6 downto 0);
    c_wdata_o : out std_logic_vector(31 downto 0);

    done_o : out std_logic;
    busy_o : out std_logic
  );
end entity;

architecture rtl of bram_shift_word32_xy16 is
  type st_t is (IDLE, RD_SET, RD_WAIT, RD_LATCH, WR, ADV, FINISH);
  signal st : st_t := IDLE;

  signal idx : unsigned(6 downto 0) := (others => '0');
  signal raddr : unsigned(6 downto 0) := (others => '0');

  signal word_reg : std_logic_vector(31 downto 0) := (others => '0');

  -- ping-pong
  signal off_x : integer := 0;
  signal off_y : integer := 0;
  signal dir_x : integer := 1;
  signal dir_y : integer := 1;
  signal delta_x : integer := 0;
  signal delta_y : integer := 0;

  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  function sat16(v : integer) return integer is
  begin
    if v > 32767 then
      return 32767;
    elsif v < -32768 then
      return -32768;
    else
      return v;
    end if;
  end function;

begin
  c_raddr_o <= raddr;

  process(clk_i)
    variable next_off_x : integer;
    variable next_dir_x : integer;
    variable next_off_y : integer;
    variable next_dir_y : integer;

    variable x_i, y_i : integer;
    variable x_n, y_n : integer;

    variable w : std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk_i) then
      c_we_o <= '0';
      done_o <= '0';

      start_p <= start_i and (not start_d);
      start_d <= start_i;

      if rstn_i = '0' then
        st <= IDLE;
        idx <= (others => '0');
        raddr <= (others => '0');
        word_reg <= (others => '0');
        off_x <= 0; off_y <= 0;
        dir_x <= 1; dir_y <= 1;
        delta_x <= 0; delta_y <= 0;
        start_d <= '0';
        start_p <= '0';
      else
        case st is
          when IDLE =>
            idx <= (others => '0');
            if start_p = '1' then
              -- compute ping-pong delta
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
            raddr <= idx;
            st <= RD_WAIT;

          when RD_WAIT =>
            st <= RD_LATCH;

          when RD_LATCH =>
            word_reg <= c_rdata_i;

            -- unpack signed int16
            x_i := to_integer(signed(c_rdata_i(15 downto 0)));
            y_i := to_integer(signed(c_rdata_i(31 downto 16)));

            x_n := sat16(x_i + delta_x);
            y_n := sat16(y_i + delta_y);

            w(15 downto 0)  := std_logic_vector(to_signed(x_n, 16));
            w(31 downto 16) := std_logic_vector(to_signed(y_n, 16));

            c_waddr_o <= idx;
            c_wdata_o <= w;
            st <= WR;

          when WR =>
            c_we_o <= '1';
            st <= ADV;

          when ADV =>
            if idx = to_unsigned(WORDS-1, idx'length) then
              st <= FINISH;
            else
              idx <= idx + 1;
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