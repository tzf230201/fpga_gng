library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bram_decay_int16 is
  generic (
    DEPTH_BYTES : natural := 400;
    STEP_X      : integer := 10;
    STEP_Y      : integer := 0;
    LIMIT_X     : integer := 300;
    LIMIT_Y     : integer := 0
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in  std_logic;

    b_raddr_o : out unsigned(8 downto 0);
    b_rdata_i : in  std_logic_vector(7 downto 0);

    b_we_o    : out std_logic;
    b_waddr_o : out unsigned(8 downto 0);
    b_wdata_o : out std_logic_vector(7 downto 0);

    done_o : out std_logic;
    busy_o : out std_logic
  );
end entity;

architecture rtl of bram_decay_int16 is
  constant PTR_W    : natural := 9;
  constant N_INT16  : natural := DEPTH_BYTES/2;

  type st_t is (
    IDLE,
    RD_LO_SET, RD_LO_WAIT, RD_LO_LATCH,
    RD_HI_SET, RD_HI_WAIT, RD_HI_LATCH,
    WR_LO, WR_HI,
    ADV, FINISH
  );
  signal st : st_t := IDLE;

  signal idx16 : unsigned(PTR_W-2 downto 0) := (others => '0');

  signal addr_lo : unsigned(PTR_W-1 downto 0);
  signal addr_hi : unsigned(PTR_W-1 downto 0);

  signal lo_b : std_logic_vector(7 downto 0) := (others => '0');
  signal hi_b : std_logic_vector(7 downto 0) := (others => '0');

  signal w_lo : std_logic_vector(7 downto 0) := (others => '0');
  signal w_hi : std_logic_vector(7 downto 0) := (others => '0');

  signal b_we    : std_logic := '0';
  signal b_waddr : unsigned(PTR_W-1 downto 0) := (others => '0');
  signal b_wdata : std_logic_vector(7 downto 0) := (others => '0');

  signal done_pulse : std_logic := '0';

  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  signal off_x  : integer := 0;
  signal off_y  : integer := 0;
  signal dir_x  : integer := 1;
  signal dir_y  : integer := 1;

  signal delta_x : integer := 0;
  signal delta_y : integer := 0;

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
  addr_lo <= (idx16 & '0');
  addr_hi <= (idx16 & '1');

  b_raddr_o <= addr_lo when (st = RD_LO_SET or st = RD_LO_WAIT or st = RD_LO_LATCH) else addr_hi;

  b_we_o    <= b_we;
  b_waddr_o <= b_waddr;
  b_wdata_o <= b_wdata;

  done_o <= done_pulse;
  busy_o <= '0' when st = IDLE else '1';

  process(clk_i)
    variable v16   : integer;
    variable vnew  : integer;
    variable addv  : integer;

    variable next_off_x : integer;
    variable next_dir_x : integer;
    variable next_off_y : integer;
    variable next_dir_y : integer;

    variable is_x : boolean;
  begin
    if rising_edge(clk_i) then
      b_we       <= '0';
      done_pulse <= '0';

      start_p <= start_i and (not start_d);
      start_d <= start_i;

      if rstn_i = '0' then
        st <= IDLE;
        idx16 <= (others => '0');
        lo_b <= (others => '0');
        hi_b <= (others => '0');
        w_lo <= (others => '0');
        w_hi <= (others => '0');
        b_waddr <= (others => '0');
        b_wdata <= (others => '0');

        off_x <= 0; off_y <= 0;
        dir_x <= 1; dir_y <= 1;
        delta_x <= 0; delta_y <= 0;

        start_d <= '0';
        start_p <= '0';

      else
        case st is
          when IDLE =>
            idx16 <= (others => '0');

            if start_p = '1' then
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

              st <= RD_LO_SET;
            end if;

          when RD_LO_SET  => st <= RD_LO_WAIT;
          when RD_LO_WAIT => st <= RD_LO_LATCH;

          when RD_LO_LATCH =>
            lo_b <= b_rdata_i;
            st   <= RD_HI_SET;

          when RD_HI_SET  => st <= RD_HI_WAIT;
          when RD_HI_WAIT => st <= RD_HI_LATCH;

          when RD_HI_LATCH =>
            hi_b <= b_rdata_i;

            -- ✅ FIX UTAMA: pakai b_rdata_i langsung (high byte terbaru)
            v16 := to_integer(signed(b_rdata_i & lo_b));

            is_x := (idx16(0) = '0');
            if is_x then
              addv := delta_x;
            else
              addv := delta_y;
            end if;

            vnew := sat16(v16 + addv);

            w_lo <= std_logic_vector(to_signed(vnew, 16)(7 downto 0));
            w_hi <= std_logic_vector(to_signed(vnew, 16)(15 downto 8));

            st <= WR_LO;

          when WR_LO =>
            b_we    <= '1';
            b_waddr <= addr_lo;
            b_wdata <= w_lo;
            st <= WR_HI;

          when WR_HI =>
            b_we    <= '1';
            b_waddr <= addr_hi;
            b_wdata <= w_hi;
            st <= ADV;

          when ADV =>
            if idx16 = to_unsigned(N_INT16-1, idx16'length) then
              st <= FINISH;
            else
              idx16 <= idx16 + 1;
              st <= RD_LO_SET;
            end if;

          when FINISH =>
            done_pulse <= '1';
            st <= IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture;
