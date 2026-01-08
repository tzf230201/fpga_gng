-- ================================================================================
-- NEORV32 CFS (Winner Finder) - SAFE (NO blocking-read)
-- ================================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;

entity neorv32_cfs is
  port (
    clk_i     : in  std_ulogic;
    rstn_i    : in  std_ulogic;
    bus_req_i : in  bus_req_t;
    bus_rsp_o : out bus_rsp_t;
    irq_o     : out std_ulogic
  );
end neorv32_cfs;

architecture neorv32_cfs_rtl of neorv32_cfs is

  constant REG_CTRL       : natural := 0;
  constant REG_COUNT      : natural := 1;

  constant REG_LAMBDA     : natural := 2;
  constant REG_A_MAX      : natural := 3;
  constant REG_EPS_B      : natural := 4;
  constant REG_EPS_N      : natural := 5;
  constant REG_ALPHA      : natural := 6;
  constant REG_D          : natural := 7;

  constant REG_XIN        : natural := 8;
  constant REG_YIN        : natural := 9;
  constant REG_NODE_COUNT : natural := 10;
  constant REG_ACT_LO     : natural := 11;
  constant REG_ACT_HI     : natural := 12;

  constant REG_OUT_S12    : natural := 13;
  constant REG_OUT_MIN1   : natural := 14;
  constant REG_OUT_MIN2   : natural := 15;

  constant MAXNODES  : natural := 40;
  constant NODE_BASE : natural := 128;

  type node_mem_t is array (0 to MAXNODES-1) of std_ulogic_vector(31 downto 0);
  signal node_mem : node_mem_t := (others => (others => '0'));

  signal xin_q15       : unsigned(15 downto 0) := (others => '0');
  signal yin_q15       : unsigned(15 downto 0) := (others => '0');
  signal node_count_u8 : unsigned(7 downto 0)  := to_unsigned(2, 8);
  signal act_lo        : std_ulogic_vector(31 downto 0) := (others => '0');
  signal act_hi        : std_ulogic_vector(7 downto 0)  := (others => '0');

  signal out_s1   : unsigned(7 downto 0)  := (others => '0');
  signal out_s2   : unsigned(7 downto 0)  := (others => '0');
  signal out_min1 : unsigned(31 downto 0) := (others => '1');
  signal out_min2 : unsigned(31 downto 0) := (others => '1');

  signal busy        : std_ulogic := '0';
  signal done        : std_ulogic := '0';
  signal start_pulse : std_ulogic := '0';
  signal clear_pulse : std_ulogic := '0';

  type fsm_t is (IDLE, RUN);
  signal fsm : fsm_t := IDLE;
  signal i_u : unsigned(7 downto 0) := (others => '0');

  signal stb_prev  : std_ulogic := '0';
  signal req_valid : std_ulogic := '0';
  signal req_rw    : std_ulogic := '0';
  signal req_ben   : std_ulogic_vector(3 downto 0) := (others => '0');
  signal req_idx_u : unsigned(13 downto 0) := (others => '0');
  signal accept    : std_ulogic;

begin

  irq_o <= '0';

  accept <= bus_req_i.stb and (not stb_prev) and (not req_valid);

  -- ==========================================================
  -- Winner FSM (1 node/clock)
  -- ==========================================================
  winner_fsm: process(clk_i, rstn_i)
    variable idx_i      : natural;
    variable ncnt       : natural;
    variable active_bit : std_ulogic;

    variable xi_u, yi_u : unsigned(15 downto 0);

    variable dx18, dy18 : signed(17 downto 0);
    variable dx2_36, dy2_36 : unsigned(35 downto 0);
    variable dist_u      : unsigned(31 downto 0);
  begin
    if rstn_i = '0' then
      fsm      <= IDLE;
      busy     <= '0';
      done     <= '0';
      i_u      <= (others => '0');
      out_s1   <= (others => '0');
      out_s2   <= (others => '0');
      out_min1 <= (others => '1');
      out_min2 <= (others => '1');

    elsif rising_edge(clk_i) then

      if clear_pulse = '1' then
        done <= '0';
        busy <= '0';
        fsm  <= IDLE;
      end if;

      if start_pulse = '1' then
        busy     <= '1';
        done     <= '0';
        fsm      <= RUN;
        i_u      <= (others => '0');
        out_min1 <= (others => '1');
        out_min2 <= (others => '1');
        out_s1   <= (others => '0');
        out_s2   <= (others => '0');
      end if;

      if fsm = RUN then
        ncnt := to_integer(node_count_u8);
        if ncnt > MAXNODES then
          ncnt := MAXNODES;
        end if;

        if to_integer(i_u) >= ncnt then
          busy <= '0';
          done <= '1';
          fsm  <= IDLE;
        else
          idx_i := to_integer(i_u);

          if idx_i < 32 then
            active_bit := act_lo(idx_i);
          else
            active_bit := act_hi(idx_i-32);
          end if;

          if active_bit = '1' then
            xi_u := unsigned(node_mem(idx_i)(15 downto 0));
            yi_u := unsigned(node_mem(idx_i)(31 downto 16));

            dx18 := resize(signed(std_ulogic_vector(xin_q15)), 18) -
                    resize(signed(std_ulogic_vector(xi_u   )), 18);
            dy18 := resize(signed(std_ulogic_vector(yin_q15)), 18) -
                    resize(signed(std_ulogic_vector(yi_u   )), 18);

            dx2_36 := unsigned(dx18 * dx18);
            dy2_36 := unsigned(dy18 * dy18);

            dist_u := resize(dx2_36(35 downto 15), 32) + resize(dy2_36(35 downto 15), 32);

            if dist_u < out_min1 then
              out_min2 <= out_min1;
              out_s2   <= out_s1;
              out_min1 <= dist_u;
              out_s1   <= to_unsigned(idx_i, 8);
            elsif dist_u < out_min2 then
              out_min2 <= dist_u;
              out_s2   <= to_unsigned(idx_i, 8);
            end if;
          end if;

          i_u <= i_u + 1;
        end if;
      end if;

    end if;
  end process;

  -- ==========================================================
  -- Bus (1-cycle response), NO blocking-read
  -- ==========================================================
  bus_access: process(clk_i, rstn_i)
    variable reg_idx : natural;
    variable di      : natural;

    constant C_LAMBDA : std_ulogic_vector(31 downto 0) := std_ulogic_vector(to_unsigned(100,32));
    constant C_A_MAX  : std_ulogic_vector(31 downto 0) := std_ulogic_vector(to_unsigned(50,32));
  begin
    if rstn_i = '0' then
      bus_rsp_o <= rsp_terminate_c;
      req_valid <= '0';
      req_rw    <= '0';
      req_ben   <= (others => '0');
      req_idx_u <= (others => '0');
      stb_prev    <= '0';
      start_pulse <= '0';
      clear_pulse <= '0';

    elsif rising_edge(clk_i) then
      stb_prev <= bus_req_i.stb;

      bus_rsp_o.ack  <= '0';
      bus_rsp_o.err  <= '0';
      bus_rsp_o.data <= (others => '0');

      start_pulse <= '0';
      clear_pulse <= '0';

      if accept = '1' then
        req_valid <= '1';
        req_rw    <= bus_req_i.rw;
        req_ben   <= bus_req_i.ben;
        req_idx_u <= unsigned(bus_req_i.addr(15 downto 2));

        reg_idx := to_integer(unsigned(bus_req_i.addr(15 downto 2)));

        if (bus_req_i.rw = '1') and (bus_req_i.ben = "1111") then
          if reg_idx = REG_CTRL then
            if bus_req_i.data(0) = '1' then clear_pulse <= '1'; end if;
            if bus_req_i.data(1) = '1' then start_pulse <= '1'; end if;

          elsif reg_idx = REG_XIN then
            xin_q15 <= unsigned(bus_req_i.data(15 downto 0));
          elsif reg_idx = REG_YIN then
            yin_q15 <= unsigned(bus_req_i.data(15 downto 0));
          elsif reg_idx = REG_NODE_COUNT then
            node_count_u8 <= unsigned(bus_req_i.data(7 downto 0));
          elsif reg_idx = REG_ACT_LO then
            act_lo <= bus_req_i.data;
          elsif reg_idx = REG_ACT_HI then
            act_hi <= bus_req_i.data(7 downto 0);

          elsif (reg_idx >= NODE_BASE) and (reg_idx < NODE_BASE + MAXNODES) then
            di := reg_idx - NODE_BASE;
            node_mem(di) <= bus_req_i.data;
          end if;
        end if;
      end if;

      if req_valid = '1' then
        req_valid     <= '0';
        bus_rsp_o.ack <= '1';
        reg_idx := to_integer(req_idx_u);

        if req_rw = '0' then
          if reg_idx = REG_CTRL then
            bus_rsp_o.data(16) <= busy;
            bus_rsp_o.data(17) <= done;

          elsif reg_idx = REG_LAMBDA then
            bus_rsp_o.data <= C_LAMBDA;
          elsif reg_idx = REG_A_MAX then
            bus_rsp_o.data <= C_A_MAX;

          elsif reg_idx = REG_XIN then
            bus_rsp_o.data(15 downto 0) <= std_ulogic_vector(xin_q15);
          elsif reg_idx = REG_YIN then
            bus_rsp_o.data(15 downto 0) <= std_ulogic_vector(yin_q15);
          elsif reg_idx = REG_NODE_COUNT then
            bus_rsp_o.data(7 downto 0) <= std_ulogic_vector(node_count_u8);
          elsif reg_idx = REG_ACT_LO then
            bus_rsp_o.data <= act_lo;
          elsif reg_idx = REG_ACT_HI then
            bus_rsp_o.data(7 downto 0) <= act_hi;

          elsif reg_idx = REG_OUT_S12 then
            bus_rsp_o.data(7 downto 0)  <= std_ulogic_vector(out_s1);
            bus_rsp_o.data(15 downto 8) <= std_ulogic_vector(out_s2);
          elsif reg_idx = REG_OUT_MIN1 then
            bus_rsp_o.data <= std_ulogic_vector(out_min1);
          elsif reg_idx = REG_OUT_MIN2 then
            bus_rsp_o.data <= std_ulogic_vector(out_min2);

          elsif (reg_idx >= NODE_BASE) and (reg_idx < NODE_BASE + MAXNODES) then
            di := reg_idx - NODE_BASE;
            bus_rsp_o.data <= node_mem(di);
          end if;
        end if;
      end if;

    end if;
  end process;

end architecture;
