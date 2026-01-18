library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity find_winner_update_error_gng is
  generic (
    MAX_NODES : natural := 40;
    ID_W      : natural := 6;   -- clog2(MAX_NODES) -> 6 untuk 40
    COORD_W   : natural := 16;
    ERR_SHIFT : natural := 0    -- best1_dist >> ERR_SHIFT sebelum ditambah ke error[30:0]
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in  std_logic; -- 1-cycle pulse

    x_i : in  signed(COORD_W-1 downto 0);
    y_i : in  signed(COORD_W-1 downto 0);

    -- mem_node: sync read 1-cycle, word32: [15:0]=x, [31:16]=y
    node_raddr_o : out unsigned(ID_W-1 downto 0);
    node_rdata_i : in  std_logic_vector(31 downto 0);

    -- mem_error: sync read 1-cycle, word32: [31]=active, [30:0]=err
    err_raddr_o  : out unsigned(ID_W-1 downto 0);
    err_rdata_i  : in  std_logic_vector(31 downto 0);

    -- mem_error write
    err_we_o     : out std_logic;
    err_waddr_o  : out unsigned(ID_W-1 downto 0);
    err_wdata_o  : out std_logic_vector(31 downto 0);

    done_o  : out std_logic; -- pulse setelah write error selesai (atau finish kalau invalid)
    busy_o  : out std_logic;

    valid_o : out std_logic; -- '1' kalau active node >= 2

    s1_id_o : out unsigned(ID_W-1 downto 0);
    s2_id_o : out unsigned(ID_W-1 downto 0);

    best1_dist_o : out unsigned(34 downto 0); -- debug
    active_cnt_o : out unsigned(ID_W downto 0)
  );
end entity;

architecture rtl of find_winner_update_error_gng is
  constant DIST_W : natural := (2*(COORD_W+1)) + 1; -- 35 untuk COORD_W=16

  type st_t is (
    IDLE,
    SET_ADDR, WAIT_RD, LATCH_CMP, NEXT_I,
    POST_SCAN,
    SET_ERR_RD, WAIT_ERR_RD, WR_ERR,
    FINISH
  );
  signal st : st_t := IDLE;

  signal idx : unsigned(ID_W-1 downto 0) := (others => '0');

  signal node_raddr : unsigned(ID_W-1 downto 0) := (others => '0');
  signal err_raddr  : unsigned(ID_W-1 downto 0) := (others => '0');

  signal s1_id  : unsigned(ID_W-1 downto 0) := (others => '0');
  signal s2_id  : unsigned(ID_W-1 downto 0) := (others => '0');
  signal best1  : unsigned(DIST_W-1 downto 0) := (others => '1');
  signal best2  : unsigned(DIST_W-1 downto 0) := (others => '1');

  signal active_cnt : unsigned(ID_W downto 0) := (others => '0');
  signal valid_ok   : std_logic := '0';

  -- start edge detect
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  -- outputs reg
  signal done_p : std_logic := '0';
  signal err_we_r : std_logic := '0';
  signal err_waddr_r : unsigned(ID_W-1 downto 0) := (others => '0');
  signal err_wdata_r : std_logic_vector(31 downto 0) := (others => '0');

begin
  node_raddr_o <= node_raddr;
  err_raddr_o  <= err_raddr;

  err_we_o    <= err_we_r;
  err_waddr_o <= err_waddr_r;
  err_wdata_o <= err_wdata_r;

  done_o <= done_p;
  busy_o <= '0' when st = IDLE else '1';

  valid_o <= valid_ok;

  s1_id_o <= s1_id;
  s2_id_o <= s2_id;

  best1_dist_o <= resize(best1, 35);
  active_cnt_o <= active_cnt;

  process(clk_i)
    variable node_x : signed(COORD_W-1 downto 0);
    variable node_y : signed(COORD_W-1 downto 0);

    variable active_v : std_logic;

    variable dx  : signed(COORD_W downto 0);
    variable dy  : signed(COORD_W downto 0);
    variable sqx : unsigned(2*(COORD_W+1)-1 downto 0);
    variable sqy : unsigned(2*(COORD_W+1)-1 downto 0);
    variable dist: unsigned(DIST_W-1 downto 0);

    -- error update
    variable cur_active : std_logic;
    variable cur_err31  : unsigned(30 downto 0);
    variable add31      : unsigned(30 downto 0);
    variable sum32      : unsigned(31 downto 0);
    variable sat31      : unsigned(30 downto 0);

    variable wr_data : std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk_i) then
      done_p    <= '0';
      err_we_r  <= '0';

      start_p <= start_i and (not start_d);
      start_d <= start_i;

      if rstn_i = '0' then
        st <= IDLE;
        idx <= (others => '0');
        node_raddr <= (others => '0');
        err_raddr  <= (others => '0');

        best1 <= (others => '1');
        best2 <= (others => '1');
        s1_id <= (others => '0');
        s2_id <= (others => '0');

        active_cnt <= (others => '0');
        valid_ok <= '0';

        err_waddr_r <= (others => '0');
        err_wdata_r <= (others => '0');

        start_d <= '0';
        start_p <= '0';

      else
        case st is
          when IDLE =>
            if start_p = '1' then
              idx <= (others => '0');

              best1 <= (others => '1');
              best2 <= (others => '1');
              s1_id <= (others => '0');
              s2_id <= (others => '0');

              active_cnt <= (others => '0');
              valid_ok <= '0';

              st <= SET_ADDR;
            end if;

          when SET_ADDR =>
            node_raddr <= idx;
            err_raddr  <= idx;
            st <= WAIT_RD;

          when WAIT_RD =>
            st <= LATCH_CMP;

          when LATCH_CMP =>
            node_x := signed(node_rdata_i(15 downto 0));
            node_y := signed(node_rdata_i(31 downto 16));
            active_v := err_rdata_i(31);

            if active_v = '1' then
              active_cnt <= active_cnt + 1;

              dx := resize(x_i, COORD_W+1) - resize(node_x, COORD_W+1);
              dy := resize(y_i, COORD_W+1) - resize(node_y, COORD_W+1);

              sqx := unsigned(dx * dx);
              sqy := unsigned(dy * dy);
              dist := resize(sqx, DIST_W) + resize(sqy, DIST_W);

              if dist < best1 then
                best2 <= best1;
                s2_id <= s1_id;

                best1 <= dist;
                s1_id <= idx;

              elsif dist < best2 then
                best2 <= dist;
                s2_id <= idx;
              end if;
            end if;

            st <= NEXT_I;

          when NEXT_I =>
            if idx = to_unsigned(MAX_NODES-1, idx'length) then
              st <= POST_SCAN;
            else
              idx <= idx + 1;
              st <= SET_ADDR;
            end if;

          when POST_SCAN =>
            if active_cnt >= to_unsigned(2, active_cnt'length) then
              valid_ok <= '1';
              st <= SET_ERR_RD;
            else
              valid_ok <= '0';
              st <= FINISH;
            end if;

          when SET_ERR_RD =>
            err_raddr <= s1_id;
            st <= WAIT_ERR_RD;

          when WAIT_ERR_RD =>
            st <= WR_ERR;

          when WR_ERR =>
            cur_active := err_rdata_i(31);
            cur_err31  := unsigned(err_rdata_i(30 downto 0));

            add31 := resize( shift_right(best1, integer(ERR_SHIFT)), 31 );

            sum32 := ("0" & cur_err31) + ("0" & add31);

            if sum32(31) = '1' then
              sat31 := (others => '1'); -- clamp
            else
              sat31 := sum32(30 downto 0);
            end if;

            wr_data := cur_active & std_logic_vector(sat31);

            err_we_r    <= '1';
            err_waddr_r <= s1_id;
            err_wdata_r <= wr_data;

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
