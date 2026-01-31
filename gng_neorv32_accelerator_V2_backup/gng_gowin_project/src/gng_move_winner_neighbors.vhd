library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng_move_winner_neighbors is
  generic (
    MAX_NODES   : natural := 40;
    EPS_W_SHIFT : natural := 3; -- winner step = 1/8
    EPS_N_SHIFT : natural := 5  -- neighbor step = 1/32
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in  std_logic;
    busy_o  : out std_logic;
    done_o  : out std_logic; -- pulse 1 clk

    -- sample
    x_i : in signed(15 downto 0);
    y_i : in signed(15 downto 0);

    -- winner + node set
    s1_i         : in unsigned(7 downto 0);
    node_count_i : in unsigned(7 downto 0);

    -- node memory (sync 1-cycle read)
    node_raddr_o : out unsigned(7 downto 0);
    node_rdata_i : in  std_logic_vector(31 downto 0);
    node_we_o    : out std_logic;
    node_waddr_o : out unsigned(7 downto 0);
    node_wdata_o : out std_logic_vector(31 downto 0);

    -- edge memory read (half adjacency, sync 1-cycle)
    edge_raddr_o : out unsigned(12 downto 0);
    edge_rdata_i : in  std_logic_vector(15 downto 0) -- bit15=valid
  );
end entity;

architecture rtl of gng_move_winner_neighbors is

  subtype u8_t  is unsigned(7 downto 0);
  subtype u13_t is unsigned(12 downto 0);
  subtype s16_t is signed(15 downto 0);

  type st_t is (
    IDLE,

    -- move winner
    MW_RD_SET, MW_RD_WAIT, MW_LATCH, MW_WRITE,

    -- move neighbors
    MN_INIT,
    MN_EDGE_SET, MN_EDGE_WAIT, MN_EDGE_LATCH,
    MN_NODE_RD_SET, MN_NODE_RD_WAIT, MN_NODE_LATCH, MN_NODE_WRITE,

    FINISH
  );

  signal st : st_t := IDLE;

  signal nb_idx : u8_t := (others => '0');

  -- local regs
  signal edge_addr_r : u13_t := (others => '0');
  signal node_addr_r : u8_t  := (others => '0');

  -- helpers
  function move1d(oldv, samp : s16_t; sh : natural) return s16_t is
    variable diff  : signed(16 downto 0);
    variable delta : signed(16 downto 0);
    variable res   : signed(16 downto 0);
  begin
    diff  := resize(samp,17) - resize(oldv,17);
    delta := shift_right(diff, integer(sh));
    res   := resize(oldv,17) + delta;
    return signed(res(15 downto 0));
  end function;

  -- half adjacency address:
  -- index for unordered pair (lo,hi) with hi>lo:
  -- addr = hi*(hi-1)/2 + lo
  function half_addr(a, b : u8_t) return u13_t is
    variable lo, hi : u8_t;
    variable hi_i   : integer;
    variable lo_i   : integer;
    variable base_i : integer;
    variable addr_i : integer;
  begin
    if a = b then
      return (others => '0');
    end if;

    if a < b then
      lo := a; hi := b;
    else
      lo := b; hi := a;
    end if;

    hi_i := to_integer(hi);
    lo_i := to_integer(lo);

    base_i := (hi_i * (hi_i - 1)) / 2;
    addr_i := base_i + lo_i;

    return to_unsigned(addr_i, 13);
  end function;

begin

  node_raddr_o <= node_addr_r;
  edge_raddr_o <= edge_addr_r;

  process(clk_i)
    variable oldx, oldy : s16_t;
    variable newx, newy : s16_t;
    variable ncnt       : integer;
    variable kint       : integer;
    variable valid_edge : std_logic;
  begin
    if rising_edge(clk_i) then
      done_o     <= '0';
      node_we_o  <= '0';
      node_waddr_o <= (others => '0');
      node_wdata_o <= (others => '0');

      if rstn_i = '0' then
        st <= IDLE;
        nb_idx <= (others => '0');
        node_addr_r <= (others => '0');
        edge_addr_r <= (others => '0');

      else
        case st is

          when IDLE =>
            if start_i='1' then
              -- start move winner
              node_addr_r <= s1_i;
              st <= MW_RD_SET;
            end if;

          -------------------------------------------------------------------
          -- MOVE WINNER
          -------------------------------------------------------------------
          when MW_RD_SET =>
            -- addr already set
            st <= MW_RD_WAIT;

          when MW_RD_WAIT =>
            st <= MW_LATCH;

          when MW_LATCH =>
            oldx := signed(node_rdata_i(15 downto 0));
            oldy := signed(node_rdata_i(31 downto 16));

            newx := move1d(oldx, x_i, EPS_W_SHIFT);
            newy := move1d(oldy, y_i, EPS_W_SHIFT);

            node_waddr_o <= s1_i;
            node_wdata_o(15 downto 0)  <= std_logic_vector(newx);
            node_wdata_o(31 downto 16) <= std_logic_vector(newy);
            st <= MW_WRITE;

          when MW_WRITE =>
            node_we_o <= '1';
            st <= MN_INIT;

          -------------------------------------------------------------------
          -- MOVE NEIGHBORS (scan k)
          -------------------------------------------------------------------
          when MN_INIT =>
            nb_idx <= (others => '0');
            st <= MN_EDGE_SET;

          when MN_EDGE_SET =>
            ncnt := to_integer(node_count_i);
            kint := to_integer(nb_idx);

            if kint >= ncnt then
              st <= FINISH;

            elsif nb_idx = s1_i then
              nb_idx <= nb_idx + 1;       -- skip winner itself
              st <= MN_EDGE_SET;

            else
              edge_addr_r <= half_addr(s1_i, nb_idx);
              st <= MN_EDGE_WAIT;
            end if;

          when MN_EDGE_WAIT =>
            st <= MN_EDGE_LATCH;

          when MN_EDGE_LATCH =>
            valid_edge := edge_rdata_i(15);
            if valid_edge='1' then
              node_addr_r <= nb_idx;
              st <= MN_NODE_RD_SET;
            else
              nb_idx <= nb_idx + 1;
              st <= MN_EDGE_SET;
            end if;

          when MN_NODE_RD_SET =>
            st <= MN_NODE_RD_WAIT;

          when MN_NODE_RD_WAIT =>
            st <= MN_NODE_LATCH;

          when MN_NODE_LATCH =>
            oldx := signed(node_rdata_i(15 downto 0));
            oldy := signed(node_rdata_i(31 downto 16));

            newx := move1d(oldx, x_i, EPS_N_SHIFT);
            newy := move1d(oldy, y_i, EPS_N_SHIFT);

            node_waddr_o <= nb_idx;
            node_wdata_o(15 downto 0)  <= std_logic_vector(newx);
            node_wdata_o(31 downto 16) <= std_logic_vector(newy);
            st <= MN_NODE_WRITE;

          when MN_NODE_WRITE =>
            node_we_o <= '1';
            nb_idx <= nb_idx + 1;
            st <= MN_EDGE_SET;

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
