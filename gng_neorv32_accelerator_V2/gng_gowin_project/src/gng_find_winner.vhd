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

    -- node set info
    node_count_i  : in unsigned(5 downto 0); -- valid nodes: 0..node_count-1
    active_mask_i : in std_logic_vector(MAX_NODES-1 downto 0);

    -- node memory read (sync 1-cycle)
    node_raddr_o : out unsigned(5 downto 0);
    node_rdata_i : in  std_logic_vector(31 downto 0); -- [15:0]=x, [31:16]=y

    -- outputs
    s1_o : out unsigned(5 downto 0);
    s2_o : out unsigned(5 downto 0);
    d1_o : out unsigned(16 downto 0) -- L1 distance (|dx|+|dy|)
  );
end entity;

architecture rtl of gng_find_winner is

  type st_t is (ST_IDLE, ST_RD_SET, ST_RD_WAIT, ST_RD_LATCH, ST_NEXT, ST_FINISH);
  signal st : st_t := ST_IDLE;

  signal idx : unsigned(5 downto 0) := (others => '0');

  signal best_id   : unsigned(5 downto 0) := (others => '0');
  signal second_id : unsigned(5 downto 0) := (others => '0');
  signal best_d    : unsigned(16 downto 0) := (others => '1');
  signal second_d  : unsigned(16 downto 0) := (others => '1');

  -- latched node x/y
  signal nx : signed(15 downto 0) := (others => '0');
  signal ny : signed(15 downto 0) := (others => '0');

  function abs17(a : signed(15 downto 0)) return unsigned is
    variable v : signed(16 downto 0);
  begin
    v := resize(a, 17);
    if v(16) = '1' then
      return unsigned(-v);
    else
      return unsigned(v);
    end if;
  end function;

begin

  node_raddr_o <= idx;

  process(clk_i)
    variable dx  : signed(15 downto 0);
    variable dy  : signed(15 downto 0);
    variable dist: unsigned(16 downto 0);
    variable ncnt: integer;
    variable iint: integer;
    variable is_active : boolean;
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
            nx <= signed(node_rdata_i(15 downto 0));
            ny <= signed(node_rdata_i(31 downto 16));

            -- compute dist & update best/second (pakai nilai node_rdata_i langsung)
            dx := x_i - signed(node_rdata_i(15 downto 0));
            dy := y_i - signed(node_rdata_i(31 downto 16));
            dist := abs17(dx) + abs17(dy);

            ncnt := to_integer(node_count_i);
            iint := to_integer(idx);

            is_active := false;
            if (iint >= 0) and (iint < ncnt) then
              if active_mask_i(iint) = '1' then
                is_active := true;
              end if;
            end if;

            if is_active then
              if dist < best_d then
                second_d  <= best_d;
                second_id <= best_id;
                best_d    <= dist;
                best_id   <= idx;
              elsif dist < second_d then
                -- biar runner-up nggak sama dengan winner
                if idx /= best_id then
                  second_d  <= dist;
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