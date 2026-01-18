library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng is
  generic (
    MAX_NODES        : natural := 40;
    DATA_WORDS       : natural := 100;
    DONE_EVERY_STEPS : natural := 10;
    LR_SHIFT         : natural := 4; -- learning rate = 1/2^LR_SHIFT
    INIT_X0          : integer := 200;
    INIT_Y0          : integer := 200;
    INIT_X1          : integer := 800;
    INIT_Y1          : integer := 800
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in std_logic;

    -- dataset read (sync 1-cycle) from mem_c
    data_raddr_o : out unsigned(6 downto 0);
    data_rdata_i : in  std_logic_vector(31 downto 0);

    gng_done_o : out std_logic;
    gng_busy_o : out std_logic;

    s1_id_o : out unsigned(5 downto 0);
    s2_id_o : out unsigned(5 downto 0)
  );
end entity;

architecture rtl of gng is
  type s16_arr is array (0 to MAX_NODES-1) of integer;
  type u32_arr is array (0 to MAX_NODES-1) of unsigned(31 downto 0);

  signal node_x : s16_arr := (others => 0);
  signal node_y : s16_arr := (others => 0);
  signal err    : u32_arr := (others => (others => '0'));

  signal active : std_logic_vector(MAX_NODES-1 downto 0) := (others => '0');
  signal node_count : integer := 2;

  signal inited : std_logic := '0';

  -- dataset index
  signal data_idx : integer range 0 to DATA_WORDS-1 := 0;
  signal data_raddr : unsigned(6 downto 0) := (others => '0');

  -- latched sample
  signal sx, sy : integer := 0;

  -- training step counter
  signal step_cnt : integer := 0;

  -- start pulse
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  type st_t is (
    ST_IDLE,
    ST_INIT,
    ST_RD_SET, ST_RD_WAIT, ST_RD_LATCH,
    ST_FIND_INIT, ST_FIND_EVAL, ST_FIND_NEXT,
    ST_UPDATE,
    ST_STEP_ADV,
    ST_DONE
  );
  signal st : st_t := ST_IDLE;

  -- find loop
  signal n_idx : integer := 0;
  signal best1_id, best2_id : integer := 0;
  signal best1_d,  best2_d  : integer := 2_000_000_000; -- big

  function sat16(v : integer) return integer is
  begin
    if v > 32767 then return 32767;
    elsif v < -32768 then return -32768;
    else return v;
    end if;
  end function;

begin
  data_raddr_o <= data_raddr;

  s1_id_o <= to_unsigned(best1_id, 6);
  s2_id_o <= to_unsigned(best2_id, 6);

  process(clk_i)
    variable dx, dy : integer;
    variable d      : integer;
    variable wx, wy : integer;
    variable upd    : integer;
    variable e_new  : unsigned(31 downto 0);
  begin
    if rising_edge(clk_i) then
      gng_done_o <= '0';

      -- edge detect
      start_p <= start_i and (not start_d);
      start_d <= start_i;

      if rstn_i = '0' then
        st <= ST_IDLE;
        inited <= '0';
        node_count <= 2;
        active <= (others => '0');
        data_idx <= 0;
        data_raddr <= (others => '0');
        sx <= 0; sy <= 0;
        step_cnt <= 0;
        start_d <= '0';
        start_p <= '0';
      else
        case st is
          when ST_IDLE =>
            if start_p = '1' then
              if inited = '0' then
                st <= ST_INIT;
              else
                step_cnt <= 0;
                st <= ST_RD_SET;
              end if;
            end if;

          when ST_INIT =>
            -- init 2 nodes fixed
            node_x(0) <= sat16(INIT_X0);
            node_y(0) <= sat16(INIT_Y0);
            node_x(1) <= sat16(INIT_X1);
            node_y(1) <= sat16(INIT_Y1);

            err(0) <= (others => '0');
            err(1) <= (others => '0');

            active(0) <= '1';
            active(1) <= '1';

            inited <= '1';
            gng_done_o <= '1'; -- done pulse after init
            -- next start will do training
            st <= ST_IDLE;

          -- read one sample from dataset (mem_c word format: [31:16]=y, [15:0]=x)
          when ST_RD_SET =>
            data_raddr <= to_unsigned(data_idx, 7);
            st <= ST_RD_WAIT;

          when ST_RD_WAIT =>
            st <= ST_RD_LATCH;

          when ST_RD_LATCH =>
            sx <= to_integer(signed(data_rdata_i(15 downto 0)));
            sy <= to_integer(signed(data_rdata_i(31 downto 16)));
            st <= ST_FIND_INIT;

          when ST_FIND_INIT =>
            best1_d  <= 2_000_000_000;
            best2_d  <= 2_000_000_000;
            best1_id <= 0;
            best2_id <= 1;
            n_idx    <= 0;
            st <= ST_FIND_EVAL;

          when ST_FIND_EVAL =>
            if (n_idx < node_count) then
              if active(n_idx) = '1' then
                dx := sx - node_x(n_idx);
                dy := sy - node_y(n_idx);
                d  := dx*dx + dy*dy;

                if d < best1_d then
                  best2_d  <= best1_d;
                  best2_id <= best1_id;
                  best1_d  <= d;
                  best1_id <= n_idx;
                elsif d < best2_d then
                  best2_d  <= d;
                  best2_id <= n_idx;
                end if;
              end if;
              st <= ST_FIND_NEXT;
            else
              st <= ST_UPDATE;
            end if;

          when ST_FIND_NEXT =>
            n_idx <= n_idx + 1;
            st <= ST_FIND_EVAL;

          when ST_UPDATE =>
            -- move winner toward sample
            wx := node_x(best1_id);
            wy := node_y(best1_id);

            upd := (sx - wx) / (2**LR_SHIFT);
            node_x(best1_id) <= sat16(wx + upd);

            upd := (sy - wy) / (2**LR_SHIFT);
            node_y(best1_id) <= sat16(wy + upd);

            -- err += best1_d (saturate)
            e_new := err(best1_id) + to_unsigned(best1_d, 32);
            err(best1_id) <= e_new;

            st <= ST_STEP_ADV;

          when ST_STEP_ADV =>
            -- advance dataset index
            if data_idx = DATA_WORDS-1 then
              data_idx <= 0;
            else
              data_idx <= data_idx + 1;
            end if;

            -- count steps, pulse done every DONE_EVERY_STEPS
            if step_cnt = integer(DONE_EVERY_STEPS-1) then
              st <= ST_DONE;
            else
              step_cnt <= step_cnt + 1;
              st <= ST_RD_SET;
            end if;

          when ST_DONE =>
            gng_done_o <= '1';
            st <= ST_IDLE;

          when others =>
            st <= ST_IDLE;
        end case;
      end if;
    end if;
  end process;

  gng_busy_o <= '0' when st = ST_IDLE else '1';
end architecture;
