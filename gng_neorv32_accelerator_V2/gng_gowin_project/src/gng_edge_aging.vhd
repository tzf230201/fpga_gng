library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity edge_aging is
  generic (
    MAX_NODES : natural := 40;
    EDGE_AW   : natural := 13;  -- keep 13-bit
    AGE_W     : natural := 8;
    A_MAX     : natural := 50
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in  std_logic;

    s1_i : in unsigned(7 downto 0);
    s2_i : in unsigned(7 downto 0);

    node_count_i : in unsigned(7 downto 0);

    busy_o : out std_logic;
    done_o : out std_logic;

    dbg_edge_raddr_i : in  unsigned(EDGE_AW-1 downto 0);
    dbg_edge_rdata_o : out std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of edge_aging is

  subtype edge_addr_t is unsigned(EDGE_AW-1 downto 0);

  function half_depth(n : natural) return natural is
  begin
    return (n * (n - 1)) / 2;
  end function;

  constant EDGE_DEPTH : natural := half_depth(MAX_NODES);

  type edge_mem_t is array (0 to EDGE_DEPTH-1) of std_logic_vector(15 downto 0);
  signal edge_mem : edge_mem_t := (others => (others => '0'));

  -- start pulse
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  -- FSM
  type st_t is (
    ST_IDLE,
    ST_SCAN_SET, ST_SCAN_WAIT, ST_SCAN_LATCH, ST_SCAN_WRITE, ST_SCAN_NEXT,
    ST_SET_SET,  ST_SET_WAIT,  ST_SET_WRITE,
    ST_FINISH
  );
  signal st : st_t := ST_IDLE;

  -- latched inputs
  signal s1_lat : unsigned(7 downto 0) := (others => '0');
  signal s2_lat : unsigned(7 downto 0) := (others => '0');
  signal nc_lat : unsigned(7 downto 0) := (others => '0');

  -- scan index
  signal k : unsigned(7 downto 0) := (others => '0');

  -- RAM interface
  signal raddr     : edge_addr_t := (others => '0');
  signal waddr     : edge_addr_t := (others => '0');
  signal we        : std_logic   := '0';
  signal wdata     : std_logic_vector(15 downto 0) := (others => '0');
  signal rdata     : std_logic_vector(15 downto 0) := (others => '0');
  signal raddr_mux : edge_addr_t := (others => '0');

  -- helper: compute half adjacency address (constrained!)
  function half_addr(a, b : unsigned(7 downto 0)) return edge_addr_t is
    variable lo, hi : unsigned(7 downto 0);
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

    -- base = hi*(hi-1)/2
    base_i := (hi_i * (hi_i - 1)) / 2;
    addr_i := base_i + lo_i;

    return to_unsigned(addr_i, EDGE_AW);
  end function;

begin

  -- start pulse (1 cycle)
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i='0' then
        start_d <= '0';
        start_p <= '0';
      else
        start_p <= start_i and (not start_d);
        start_d <= start_i;
      end if;
    end if;
  end process;

  busy_o <= '0' when st = ST_IDLE else '1';

  -- when idle: allow debug address to read memory
  raddr_mux <= dbg_edge_raddr_i when (st = ST_IDLE) else raddr;

  -- sync RAM: write and read (no read-before-write dependency)
  process(clk_i)
    variable ra : integer;
    variable wa : integer;
  begin
    if rising_edge(clk_i) then
      if we='1' then
        wa := to_integer(waddr);
        if (wa >= 0) and (wa < integer(EDGE_DEPTH)) then
          edge_mem(wa) <= wdata;
        end if;
      end if;

      ra := to_integer(raddr_mux);
      if (ra >= 0) and (ra < integer(EDGE_DEPTH)) then
        rdata <= edge_mem(ra);
      else
        rdata <= (others => '0');
      end if;
    end if;
  end process;

  dbg_edge_rdata_o <= rdata;

  -- FSM
  process(clk_i)
    variable ncnt    : integer;
    variable kk      : integer;
    variable valid   : std_logic;
    variable age     : unsigned(AGE_W-1 downto 0);
    variable max_age : unsigned(AGE_W-1 downto 0);
    variable new_w   : std_logic_vector(15 downto 0);
    variable a       : edge_addr_t;
  begin
    if rising_edge(clk_i) then
      we     <= '0';
      done_o <= '0';

      if rstn_i='0' then
        st     <= ST_IDLE;
        s1_lat <= (others => '0');
        s2_lat <= (others => '0');
        nc_lat <= (others => '0');
        k      <= (others => '0');
        raddr  <= (others => '0');
        waddr  <= (others => '0');
        wdata  <= (others => '0');

      else
        max_age := to_unsigned(A_MAX, AGE_W);

        case st is
          when ST_IDLE =>
            if start_p='1' then
              s1_lat <= s1_i;
              s2_lat <= s2_i;
              nc_lat <= node_count_i;
              k      <= (others => '0');
              st     <= ST_SCAN_SET;
            end if;

          -- scan edges (s1,k)
          when ST_SCAN_SET =>
            ncnt := to_integer(nc_lat);
            kk   := to_integer(k);

            if (ncnt <= 0) then
              st <= ST_SET_SET;
            elsif kk >= ncnt then
              st <= ST_SET_SET;
            elsif k = s1_lat then
              k  <= k + 1;
              st <= ST_SCAN_SET;
            else
              a := half_addr(s1_lat, k);
              raddr <= a;
              st <= ST_SCAN_WAIT;
            end if;

          when ST_SCAN_WAIT =>
            st <= ST_SCAN_LATCH;

          when ST_SCAN_LATCH =>
            valid := rdata(15);
            age   := unsigned(rdata(AGE_W-1 downto 0));

            if valid = '1' then
              if age >= max_age then
                new_w := (others => '0'); -- delete
              else
                new_w := (others => '0');
                new_w(15) := '1';
                new_w(AGE_W-1 downto 0) := std_logic_vector(age + 1);
              end if;

              waddr <= raddr;
              wdata <= new_w;
              st    <= ST_SCAN_WRITE;
            else
              st <= ST_SCAN_NEXT;
            end if;

          when ST_SCAN_WRITE =>
            we <= '1';
            st <= ST_SCAN_NEXT;

          when ST_SCAN_NEXT =>
            k  <= k + 1;
            st <= ST_SCAN_SET;

          -- ensure edge(s1,s2) valid with age=0
          when ST_SET_SET =>
            if s1_lat = s2_lat then
              st <= ST_FINISH;
            else
              a := half_addr(s1_lat, s2_lat);
              raddr <= a;
              st <= ST_SET_WAIT;
            end if;

          when ST_SET_WAIT =>
            st <= ST_SET_WRITE;

          when ST_SET_WRITE =>
            waddr <= raddr;
            wdata <= (15 => '1', others => '0'); -- valid=1 age=0
            we    <= '1';
            st    <= ST_FINISH;

          when ST_FINISH =>
            done_o <= '1';
            st <= ST_IDLE;

          when others =>
            st <= ST_IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture;
