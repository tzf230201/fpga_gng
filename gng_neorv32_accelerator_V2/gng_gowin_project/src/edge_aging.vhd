-- edge_aging.vhd
-- Edge aging engine using half adjacency matrix (packed lower triangle)
-- Memory stores {valid, age} per edge.
--
-- Address mapping (half matrix):
--   hi = max(a,b), lo = min(a,b), hi != lo
--   addr = TRI_BASE(hi) + lo
-- where TRI_BASE(i) = i*(i-1)/2, implemented as a compile-time LUT.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity edge_aging is
  generic (
    MAX_NODES : natural := 100;  -- up to 255 recommended with 8-bit IDs
    EDGE_AW   : natural := 13;   -- 13-bit covers up to 8192 edges (N=100 => 4950)
    AGE_W     : natural := 8;    -- age bits
    A_MAX     : natural := 50    -- remove if age > A_MAX
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    -- one "sample" trigger (pulse)
    start_i : in  std_logic;

    -- winner + runner-up
    s1_i : in unsigned(7 downto 0);
    s2_i : in unsigned(7 downto 0);

    -- current number of valid nodes (0..node_count-1)
    node_count_i : in unsigned(7 downto 0);

    busy_o : out std_logic;
    done_o : out std_logic;

    -- debug read (sync 1-cycle)
    dbg_edge_raddr_i : in  unsigned(EDGE_AW-1 downto 0);
    dbg_edge_rdata_o : out std_logic_vector(15 downto 0)  -- bit15=valid, [7:0]=age
  );
end entity;

architecture rtl of edge_aging is

  ---------------------------------------------------------------------------
  -- Constants / Types
  ---------------------------------------------------------------------------
  constant MAX_EDGES : natural := (MAX_NODES * (MAX_NODES - 1)) / 2;

  subtype edge_addr_t is unsigned(EDGE_AW-1 downto 0);
  subtype age_t       is unsigned(AGE_W-1 downto 0);

  -- edge word: [AGE_W] = valid, [AGE_W-1:0]=age
  subtype edge_word_t is std_logic_vector(AGE_W downto 0);

  type edge_mem_t is array (0 to MAX_EDGES-1) of edge_word_t;

  -- Triangular base LUT: TRI_BASE(i) = i*(i-1)/2
  type tri_t is array (0 to MAX_NODES-1) of edge_addr_t;

  function build_tri return tri_t is
    variable t   : tri_t;
    variable acc : natural := 0;
  begin
    t(0) := (others => '0');
    acc := 0;
    for i in 1 to MAX_NODES-1 loop
      acc := acc + (i-1);
      t(i) := to_unsigned(acc, EDGE_AW);
    end loop;
    return t;
  end function;

  constant TRI_BASE : tri_t := build_tri;

  -- Address mapper (caller must ensure a,b in range and a/=b)
  function edge_addr(a : unsigned(7 downto 0); b : unsigned(7 downto 0)) return edge_addr_t is
    variable ai, bi : integer;
    variable hi, lo : integer;
    variable base   : edge_addr_t;
  begin
    ai := to_integer(a);
    bi := to_integer(b);

    if ai = bi then
      return (others => '0'); -- invalid; caller should avoid
    end if;

    if ai > bi then
      hi := ai; lo := bi;
    else
      hi := bi; lo := ai;
    end if;

    base := TRI_BASE(hi);
    return base + to_unsigned(lo, EDGE_AW);
  end function;

  ---------------------------------------------------------------------------
  -- Helper functions (placed here for tool compatibility)
  ---------------------------------------------------------------------------
  function cap_node_count(nc : unsigned(7 downto 0)) return integer is
    variable v : integer;
  begin
    v := to_integer(nc);
    if v < 0 then v := 0; end if;
    if v > integer(MAX_NODES) then v := integer(MAX_NODES); end if;
    return v;
  end function;

  function in_range_id(id : unsigned(7 downto 0); ncnt : integer) return boolean is
    variable v : integer;
  begin
    v := to_integer(id);
    return (v >= 0) and (v < ncnt);
  end function;

  ---------------------------------------------------------------------------
  -- RAM (true dual-port style)
  -- Port A: internal aging engine (read + optional write, sync 1-cycle read)
  -- Port B: debug read only (sync 1-cycle read)
  ---------------------------------------------------------------------------
  signal mem : edge_mem_t := (others => (others => '0'));

  signal a_addr  : edge_addr_t := (others => '0');
  signal a_we    : std_logic := '0';
  signal a_wdata : edge_word_t := (others => '0');
  signal a_rdata : edge_word_t := (others => '0');

  signal b_addr  : edge_addr_t := (others => '0');
  signal b_rdata : edge_word_t := (others => '0');

  ---------------------------------------------------------------------------
  -- Control / FSM
  ---------------------------------------------------------------------------
  type st_t is (
    ST_INIT,          -- clear mem
    ST_IDLE,
    ST_AGE_SET,       -- set addr for edge(s1,k)
    ST_AGE_WAIT,      -- wait 1 cycle
    ST_AGE_LATCH,     -- latch and decide
    ST_AGE_WRITE,     -- write updated word
    ST_AGE_WWAIT,     -- wait 1 cycle after write
    ST_SETEDGE_WRITE, -- set/create edge(s1,s2) age=0
    ST_SETEDGE_WWAIT,
    ST_DONE
  );
  signal st : st_t := ST_INIT;

  -- init clear index
  signal clr_i : edge_addr_t := (others => '0');

  -- start edge detect
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  -- latched sample data
  signal s1_l   : unsigned(7 downto 0) := (others => '0');
  signal s2_l   : unsigned(7 downto 0) := (others => '0');
  signal ncnt_l : unsigned(7 downto 0) := (others => '0');

  -- scan index k
  signal k : unsigned(7 downto 0) := (others => '0');

  -- helper addr reg
  signal addr_cur : edge_addr_t := (others => '0');

begin

  ---------------------------------------------------------------------------
  -- start pulse detect
  ---------------------------------------------------------------------------
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

  ---------------------------------------------------------------------------
  -- Dual-port RAM (sync read)
  ---------------------------------------------------------------------------
  process(clk_i)
    variable ia : integer;
    variable ib : integer;
  begin
    if rising_edge(clk_i) then
      ia := to_integer(a_addr);
      ib := to_integer(b_addr);

      -- write port A
      if a_we = '1' then
        if (ia >= 0) and (ia < integer(MAX_EDGES)) then
          mem(ia) <= a_wdata;
        end if;
      end if;

      -- read port A
      if (ia >= 0) and (ia < integer(MAX_EDGES)) then
        a_rdata <= mem(ia);
      else
        a_rdata <= (others => '0');
      end if;

      -- read port B (debug)
      if (ib >= 0) and (ib < integer(MAX_EDGES)) then
        b_rdata <= mem(ib);
      else
        b_rdata <= (others => '0');
      end if;
    end if;
  end process;

  -- debug address always driven
  b_addr <= dbg_edge_raddr_i;

  -- debug output format: bit15=valid, [7:0]=age
  process(clk_i)
    variable v : std_logic;
    variable a : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk_i) then
      v := b_rdata(AGE_W);
      a := (others => '0');
      if AGE_W >= 8 then
        a := b_rdata(7 downto 0);
      else
        a(AGE_W-1 downto 0) := b_rdata(AGE_W-1 downto 0);
      end if;

      dbg_edge_rdata_o <= (others => '0');
      dbg_edge_rdata_o(15)         <= v;
      dbg_edge_rdata_o(7 downto 0) <= a;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- FSM
  ---------------------------------------------------------------------------
  process(clk_i)
    variable ncnt_int : integer;
    variable k_int    : integer;

    variable valid    : std_logic;
    variable age_u    : age_t;
    variable new_age  : unsigned(AGE_W downto 0); -- one extra bit for compare
    variable wr_word  : edge_word_t;              -- VARIABLE (must use :=)
  begin
    if rising_edge(clk_i) then
      a_we   <= '0';
      done_o <= '0';

      if rstn_i='0' then
        st     <= ST_INIT;
        clr_i  <= (others => '0');
        a_addr <= (others => '0');
        a_we   <= '0';
        a_wdata<= (others => '0');

        s1_l   <= (others => '0');
        s2_l   <= (others => '0');
        ncnt_l <= (others => '0');
        k      <= (others => '0');
        addr_cur <= (others => '0');

      else
        case st is

          -------------------------------------------------------------------
          -- Clear all edges after reset
          -------------------------------------------------------------------
          when ST_INIT =>
            a_addr  <= clr_i;
            a_we    <= '1';
            a_wdata <= (others => '0');

            if clr_i = to_unsigned(MAX_EDGES-1, EDGE_AW) then
              st <= ST_IDLE;
            else
              clr_i <= clr_i + 1;
            end if;

          when ST_IDLE =>
            if start_p='1' then
              s1_l   <= s1_i;
              s2_l   <= s2_i;
              ncnt_l <= node_count_i;

              k  <= (others => '0');
              st <= ST_AGE_SET;
            end if;

          -------------------------------------------------------------------
          -- Age all edges incident to s1 (except self)
          -------------------------------------------------------------------
          when ST_AGE_SET =>
            ncnt_int := cap_node_count(ncnt_l);
            k_int    := to_integer(k);

            if k_int >= ncnt_int then
              st <= ST_SETEDGE_WRITE;
            elsif k = s1_l then
              k  <= k + 1;
              st <= ST_AGE_SET;
            else
              addr_cur <= edge_addr(s1_l, k);
              a_addr   <= edge_addr(s1_l, k);
              st <= ST_AGE_WAIT;
            end if;

          when ST_AGE_WAIT =>
            st <= ST_AGE_LATCH;

          when ST_AGE_LATCH =>
            valid := a_rdata(AGE_W);
            age_u := unsigned(a_rdata(AGE_W-1 downto 0));

            if valid = '1' then
              new_age := resize(age_u, AGE_W+1) + 1;

              if new_age > to_unsigned(A_MAX, AGE_W+1) then
                -- remove edge
                wr_word := (others => '0');
              else
                -- keep edge, update age
                wr_word := (others => '0');
                wr_word(AGE_W) := '1';
                wr_word(AGE_W-1 downto 0) := std_logic_vector(new_age(AGE_W-1 downto 0));
              end if;

              a_addr  <= addr_cur;
              a_wdata <= wr_word;
              a_we    <= '1';
              st <= ST_AGE_WRITE;

            else
              k  <= k + 1;
              st <= ST_AGE_SET;
            end if;

          when ST_AGE_WRITE =>
            a_we <= '0';
            st <= ST_AGE_WWAIT;

          when ST_AGE_WWAIT =>
            k  <= k + 1;
            st <= ST_AGE_SET;

          -------------------------------------------------------------------
          -- (Re)connect edge(s1,s2) with age=0
          -------------------------------------------------------------------
          when ST_SETEDGE_WRITE =>
            ncnt_int := cap_node_count(ncnt_l);

            if in_range_id(s1_l, ncnt_int) and in_range_id(s2_l, ncnt_int) and (s1_l /= s2_l) then
              addr_cur <= edge_addr(s1_l, s2_l);
              a_addr   <= edge_addr(s1_l, s2_l);

              wr_word := (others => '0');
              wr_word(AGE_W) := '1'; -- valid
              wr_word(AGE_W-1 downto 0) := (others => '0'); -- age=0

              a_wdata <= wr_word;
              a_we    <= '1';
              st <= ST_SETEDGE_WWAIT;
            else
              st <= ST_DONE;
            end if;

          when ST_SETEDGE_WWAIT =>
            a_we <= '0';
            st <= ST_DONE;

          when ST_DONE =>
            done_o <= '1';
            st <= ST_IDLE;

          when others =>
            st <= ST_IDLE;

        end case;
      end if;
    end if;
  end process;

  busy_o <= '0' when (st = ST_IDLE) else '1';

end architecture;
