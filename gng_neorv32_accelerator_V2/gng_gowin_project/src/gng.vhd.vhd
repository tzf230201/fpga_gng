library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng is
  generic (
    WORDS       : natural := 100;
    MAX_NODES   : natural := 32;
    LEARN_SHIFT : natural := 4;      -- 1/16
    MAX_STEPS   : natural := 10000   -- termination flag threshold
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    init_i : in  std_logic; -- pulse
    step_i : in  std_logic; -- pulse

    c_raddr_o : out unsigned(6 downto 0);
    c_rdata_i : in  std_logic_vector(31 downto 0);

    done_o : out std_logic; -- pulse after init or one-step
    busy_o : out std_logic;
    term_o : out std_logic
  );
end entity;

architecture rtl of gng is
  type node_arr_t is array (0 to MAX_NODES-1) of signed(15 downto 0);
  type err_arr_t  is array (0 to MAX_NODES-1) of unsigned(31 downto 0);

  signal node_x : node_arr_t;
  signal node_y : node_arr_t;
  signal err    : err_arr_t;

  signal node_cnt : natural range 0 to MAX_NODES := 2;

  signal pt_idx : unsigned(6 downto 0) := (others => '0');
  signal steps  : unsigned(31 downto 0) := (others => '0');

  -- start edge detect
  signal init_d, step_d : std_logic := '0';
  signal init_p, step_p : std_logic := '0';

  type st_t is (
    IDLE,
    DO_INIT,
    RD_SET, RD_WAIT, RD_LATCH,
    SCAN_PREP, SCAN_ONE, UPDATE_WIN, FINISH_STEP
  );
  signal st : st_t := IDLE;

  signal done_p : std_logic := '0';

  signal scan_i : natural range 0 to MAX_NODES-1 := 0;
  signal winner : natural range 0 to MAX_NODES-1 := 0;

  signal pt_x : signed(15 downto 0) := (others => '0');
  signal pt_y : signed(15 downto 0) := (others => '0');

  signal best_d : unsigned(31 downto 0) := (others => '1'); -- large

  function abs16(v : signed(15 downto 0)) return unsigned is
    variable vv : signed(15 downto 0);
  begin
    vv := v;
    if vv(vv'high) = '1' then
      vv := -vv;
    end if;
    return unsigned(vv);
  end function;

begin
  done_o <= done_p;
  busy_o <= '0' when st = IDLE else '1';
  term_o <= '1' when (steps >= to_unsigned(MAX_STEPS, steps'length)) else '0';

  -- dataset address
  c_raddr_o <= pt_idx;

  process(clk_i)
    variable dx, dy : signed(15 downto 0);
    variable dcur   : unsigned(31 downto 0);
    variable upd_x, upd_y : signed(15 downto 0);
    variable ddx, ddy : signed(15 downto 0);
  begin
    if rising_edge(clk_i) then
      done_p <= '0';

      init_p <= init_i and (not init_d);
      init_d <= init_i;

      step_p <= step_i and (not step_d);
      step_d <= step_i;

      if rstn_i = '0' then
        st <= IDLE;
        pt_idx <= (others => '0');
        steps  <= (others => '0');
        node_cnt <= 2;
        for i in 0 to MAX_NODES-1 loop
          node_x(i) <= (others => '0');
          node_y(i) <= (others => '0');
          err(i)    <= (others => '0');
        end loop;

      else
        case st is
          when IDLE =>
            if init_p = '1' then
              st <= DO_INIT;
            elsif step_p = '1' then
              -- start one training step (read pt_idx)
              st <= RD_SET;
            end if;

          when DO_INIT =>
            -- node_0=(0.2,0.2)->200 ; node_1=(0.8,0.8)->800 (SCALE=1000)
            node_x(0) <= to_signed(200,16);
            node_y(0) <= to_signed(200,16);
            node_x(1) <= to_signed(800,16);
            node_y(1) <= to_signed(800,16);
            for i in 0 to MAX_NODES-1 loop
              err(i) <= (others => '0');
            end loop;
            pt_idx <= (others => '0');
            steps  <= (others => '0');
            node_cnt <= 2;
            done_p <= '1';
            st <= IDLE;

          when RD_SET =>
            -- c_raddr_o already pt_idx
            st <= RD_WAIT;

          when RD_WAIT =>
            st <= RD_LATCH;

          when RD_LATCH =>
            pt_x <= signed(c_rdata_i(15 downto 0));
            pt_y <= signed(c_rdata_i(31 downto 16));
            st <= SCAN_PREP;

          when SCAN_PREP =>
            scan_i <= 0;
            winner <= 0;
            best_d <= (others => '1');
            st <= SCAN_ONE;

          when SCAN_ONE =>
            dx := pt_x - node_x(scan_i);
            dy := pt_y - node_y(scan_i);
            -- cheap distance: L1 = |dx| + |dy|
            dcur := resize(abs16(dx), 32) + resize(abs16(dy), 32);

            if dcur < best_d then
              best_d <= dcur;
              winner <= scan_i;
            end if;

            if scan_i = node_cnt-1 then
              st <= UPDATE_WIN;
            else
              scan_i <= scan_i + 1;
            end if;

          when UPDATE_WIN =>
            -- winner update: w += (p-w)/2^LEARN_SHIFT
            ddx := pt_x - node_x(winner);
            ddy := pt_y - node_y(winner);

            upd_x := node_x(winner) + shift_right(ddx, integer(LEARN_SHIFT));
            upd_y := node_y(winner) + shift_right(ddy, integer(LEARN_SHIFT));

            node_x(winner) <= upd_x;
            node_y(winner) <= upd_y;

            err(winner) <= err(winner) + best_d;

            st <= FINISH_STEP;

          when FINISH_STEP =>
            steps <= steps + 1;

            if pt_idx = to_unsigned(WORDS-1, pt_idx'length) then
              pt_idx <= (others => '0');
            else
              pt_idx <= pt_idx + 1;
            end if;

            done_p <= '1';
            st <= IDLE;

          when others =>
            st <= IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture;
