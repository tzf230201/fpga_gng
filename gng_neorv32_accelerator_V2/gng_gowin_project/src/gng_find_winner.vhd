library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng_find_winner is
  generic (
    MAX_NODES : natural := 40
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in  std_logic;
    busy_o  : out std_logic;
    done_o  : out std_logic;

    -- sample input
    x_i : in signed(15 downto 0);
    y_i : in signed(15 downto 0);

    -- node set info (8-bit system)
    node_count_i  : in unsigned(7 downto 0); -- valid nodes: 0..node_count-1
    active_mask_i : in std_logic_vector(MAX_NODES-1 downto 0);

    -- node memory read (sync 1-cycle)
    node_raddr_o : out unsigned(7 downto 0);
    node_rdata_i : in  std_logic_vector(31 downto 0); -- [15:0]=x, [31:16]=y

    -- outputs (8-bit IDs)
    s1_o : out unsigned(7 downto 0);
    s2_o : out unsigned(7 downto 0);

    -- L2^2 distance (dx^2 + dy^2), 33-bit
    d1_o : out unsigned(32 downto 0)
  );
end entity;

architecture rtl of gng_find_winner is

  subtype u8_t  is unsigned(7 downto 0);
  subtype u16_t is unsigned(15 downto 0);
  subtype u32_t is unsigned(31 downto 0);
  subtype u33_t is unsigned(32 downto 0);

  type st_t is (ST_IDLE, ST_RD_SET, ST_RD_WAIT, ST_RD_LATCH, ST_NEXT, ST_FINISH);
  signal st : st_t := ST_IDLE;

  signal idx : u8_t := (others => '0');

  signal best_id   : u8_t := (others => '0');
  signal second_id : u8_t := (others => '0');

  signal best_d    : u33_t := (others => '1');
  signal second_d  : u33_t := (others => '1');

  -- optional debug latch
  signal nx : signed(15 downto 0) := (others => '0');
  signal ny : signed(15 downto 0) := (others => '0');

  -- abs(signed17) -> unsigned16 (step-by-step, Gowin friendly)
  function abs_u16(a : signed(16 downto 0)) return u16_t is
    variable v : signed(16 downto 0);
    variable r : u16_t;
  begin
    v := a;
    if v(16) = '1' then
      v := -v;
    end if;
    r := unsigned(v(15 downto 0));
    return r;
  end function;

  -- square unsigned16 -> unsigned32
  function sq_u32(u : u16_t) return u32_t is
    variable p : u32_t;
  begin
    p := u * u;  -- 16*16 -> 32 bit
    return p;
  end function;

begin

  node_raddr_o <= idx;

  process(clk_i)
    variable dx17     : signed(16 downto 0);
    variable dy17     : signed(16 downto 0);

    variable adx      : u16_t;
    variable ady      : u16_t;

    variable sx       : u32_t;
    variable sy       : u32_t;

    variable dist33   : u33_t;

    variable ncnt     : integer;
    variable iint     : integer;
    variable is_active: boolean;

    variable node_x   : signed(15 downto 0);
    variable node_y   : signed(15 downto 0);
  begin
    if rising_edge(clk_i) then
      done_o <= '0';

      if rstn_i = '0' then
        st        <= ST_IDLE;
        idx       <= (others => '0');

        best_id   <= (others => '0');
        second_id <= (others => '0');
        best_d    <= (others => '1');
        second_d  <= (others => '1');

        nx        <= (others => '0');
        ny        <= (others => '0');

      else
        case st is

          when ST_IDLE =>
            if start_i = '1' then
              idx       <= (others => '0');
              best_id   <= (others => '0');
              second_id <= (others => '0');
              best_d    <= (others => '1');
              second_d  <= (others => '1');
              st        <= ST_RD_SET;
            end if;

          when ST_RD_SET =>
            -- address already on node_raddr_o via idx
            st <= ST_RD_WAIT;

          when ST_RD_WAIT =>
            -- wait 1 cycle for node_rdata_i
            st <= ST_RD_LATCH;

          when ST_RD_LATCH =>
            node_x := signed(node_rdata_i(15 downto 0));
            node_y := signed(node_rdata_i(31 downto 16));

            nx <= node_x;
            ny <= node_y;

            -- dx,dy in 17-bit to avoid overflow
            dx17 := resize(x_i, 17) - resize(node_x, 17);
            dy17 := resize(y_i, 17) - resize(node_y, 17);

            adx := abs_u16(dx17);
            ady := abs_u16(dy17);

            sx := sq_u32(adx);
            sy := sq_u32(ady);

            dist33 := ('0' & sx) + ('0' & sy);  -- 33-bit sum

            ncnt := to_integer(node_count_i);
            iint := to_integer(idx);

            -- SAFE active check
            is_active := false;
            if (iint >= 0) and (iint < ncnt) and (iint < integer(MAX_NODES)) then
              if active_mask_i(iint) = '1' then
                is_active := true;
              end if;
            end if;

            if is_active then
              if dist33 < best_d then
                second_d  <= best_d;
                second_id <= best_id;

                best_d    <= dist33;
                best_id   <= idx;

              elsif dist33 < second_d then
                if idx /= best_id then
                  second_d  <= dist33;
                  second_id <= idx;
                end if;
              end if;
            end if;

            st <= ST_NEXT;

          when ST_NEXT =>
            ncnt := to_integer(node_count_i);

            if ncnt <= 0 then
              st <= ST_FINISH;

            elsif idx = to_unsigned(ncnt-1, idx'length) then
              st <= ST_FINISH;

            else
              idx <= idx + 1;
              st  <= ST_RD_SET;
            end if;

          when ST_FINISH =>
            done_o <= '1';
            st <= ST_IDLE;

          when others =>
            st <= ST_IDLE;

        end case;
      end if;
    end if;
  end process;

  busy_o <= '0' when st = ST_IDLE else '1';

  s1_o <= best_id;
  s2_o <= second_id;
  d1_o <= best_d;

end architecture;
