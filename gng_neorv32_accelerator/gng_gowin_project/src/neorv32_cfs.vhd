-- ================================================================================
-- NEORV32 SoC - Custom Functions Subsystem (CFS)
-- Winner finder accelerator (s1/s2) + dataset storage + settings regs
-- + EDGE BRAM storage (REG[EDGE_BASE..EDGE_BASE+MAXEDGES-1])
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
    irq_o     : out std_ulogic;
    cfs_in_i  : in  std_ulogic_vector(255 downto 0);
    cfs_out_o : out std_ulogic_vector(255 downto 0)
  );
end neorv32_cfs;

architecture neorv32_cfs_rtl of neorv32_cfs is

  -- -------------------------------
  -- Address map (word index REG[idx])
  -- -------------------------------
  constant REG_CTRL       : natural := 0;  -- bit0=CLEAR, bit1=START (writes), bit16=BUSY, bit17=DONE (reads)
  constant REG_COUNT      : natural := 1;

  -- settings regs (optional, stored only)
  constant REG_LAMBDA     : natural := 2;
  constant REG_A_MAX      : natural := 3;
  constant REG_EPS_B      : natural := 4;  -- Q0.16 in [15:0]
  constant REG_EPS_N      : natural := 5;
  constant REG_ALPHA      : natural := 6;
  constant REG_D          : natural := 7;

  -- winner input regs
  constant REG_XIN        : natural := 8;  -- Q1.15 in [15:0]
  constant REG_YIN        : natural := 9;  -- Q1.15 in [15:0]
  constant REG_NODE_COUNT : natural := 10; -- [7:0]
  constant REG_ACT_LO     : natural := 11; -- 32-bit mask for node 0..31
  constant REG_ACT_HI     : natural := 12; -- [7:0] mask for node 32..39

  -- winner output regs
  constant REG_OUT_S12    : natural := 13; -- [7:0]=s1, [15:8]=s2
  constant REG_OUT_MIN1   : natural := 14; -- u32
  constant REG_OUT_MIN2   : natural := 15; -- u32

  -- dataset mem
  constant MAXPTS    : natural := 100;
  constant DATA_BASE : natural := 16;  -- REG[16..115]

  -- node mem (positions)
  constant MAXNODES  : natural := 40;
  constant NODE_BASE : natural := 128; -- REG[128..167]

  -- edge mem (NEW)
  constant MAXEDGES  : natural := 80;
  constant EDGE_BASE : natural := 168; -- REG[168..247]

  -- -------------------------------
  -- storage
  -- -------------------------------
  type data_mem_t is array (0 to MAXPTS-1) of std_ulogic_vector(31 downto 0);
  signal data_mem : data_mem_t := (others => (others => '0'));

  type node_mem_t is array (0 to MAXNODES-1) of std_ulogic_vector(31 downto 0);
  signal node_mem : node_mem_t := (others => (others => '0'));

  -- Edge word format:
  -- [7:0]=a, [15:8]=b, [23:16]=age, [24]=active, others=0
  type edge_mem_t is array (0 to MAXEDGES-1) of std_ulogic_vector(31 downto 0);
  signal edge_mem : edge_mem_t := (others => (others => '0'));

  signal count_u   : unsigned(31 downto 0) := (others => '0');

  -- settings storage
  signal lambda_u  : unsigned(31 downto 0) := to_unsigned(100, 32);
  signal amax_u    : unsigned(31 downto 0) := to_unsigned(50, 32);
  signal eps_b_q16 : unsigned(15 downto 0) := to_unsigned(19661, 16);
  signal eps_n_q16 : unsigned(15 downto 0) := to_unsigned(65, 16);
  signal alpha_q16 : unsigned(15 downto 0) := to_unsigned(32768, 16);
  signal d_q16     : unsigned(15 downto 0) := to_unsigned(65101, 16);

  -- winner inputs
  signal xin_q15       : unsigned(15 downto 0) := (others => '0');
  signal yin_q15       : unsigned(15 downto 0) := (others => '0');
  signal node_count_u8 : unsigned(7 downto 0)  := to_unsigned(2, 8);
  signal act_lo        : std_ulogic_vector(31 downto 0) := (others => '0');
  signal act_hi        : std_ulogic_vector(7 downto 0)  := (others => '0');

  -- winner outputs
  signal out_s1   : unsigned(7 downto 0) := (others => '0');
  signal out_s2   : unsigned(7 downto 0) := (others => '0');
  signal out_min1 : unsigned(31 downto 0) := (others => '1');
  signal out_min2 : unsigned(31 downto 0) := (others => '1');

  -- control/status
  signal busy        : std_ulogic := '0';
  signal done        : std_ulogic := '0';
  signal start_pulse : std_ulogic := '0';
  signal clear_pulse : std_ulogic := '0';

  type fsm_t is (IDLE, RUN);
  signal fsm : fsm_t := IDLE;
  signal i_u : unsigned(7 downto 0) := (others => '0');

begin

  cfs_out_o <= (others => '0');
  irq_o     <= '0';

  -- ==========================================================
  -- Winner finder FSM (1 node/clock)
  -- node word format: [15:0]=x_q15, [31:16]=y_q15
  -- dist = (xin-xi)^2 + (yin-yi)^2  (32-bit)
  -- ==========================================================
  winner_fsm: process(clk_i, rstn_i)
    variable idx_i      : natural;
    variable ncnt       : natural;
    variable active_bit : std_ulogic;

    variable xi_u, yi_u : unsigned(15 downto 0);
    variable dx_s, dy_s : signed(15 downto 0);

    variable dx2_u, dy2_u : unsigned(31 downto 0);
    variable dist_u       : unsigned(31 downto 0);
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

          -- active check
          if idx_i < 32 then
            active_bit := act_lo(idx_i);
          else
            active_bit := act_hi(idx_i-32);
          end if;

          if active_bit = '1' then
            xi_u := unsigned(node_mem(idx_i)(15 downto 0));
            yi_u := unsigned(node_mem(idx_i)(31 downto 16));

            dx_s := signed(xin_q15) - signed(xi_u);
            dy_s := signed(yin_q15) - signed(yi_u);

            dx2_u := unsigned(dx_s * dx_s);
            dy2_u := unsigned(dy_s * dy_s);

            dist_u := dx2_u + dy2_u;

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
  -- Bus access
  -- ==========================================================
  bus_access: process(clk_i, rstn_i)
    variable reg_idx : natural;
    variable di      : natural;
  begin
    if rstn_i = '0' then
      bus_rsp_o <= rsp_terminate_c;
      start_pulse <= '0';
      clear_pulse <= '0';

    elsif rising_edge(clk_i) then
      -- default
      bus_rsp_o.ack  <= bus_req_i.stb;
      bus_rsp_o.err  <= '0';
      bus_rsp_o.data <= (others => '0');

      start_pulse <= '0';
      clear_pulse <= '0';

      if bus_req_i.stb = '1' then
        reg_idx := to_integer(unsigned(bus_req_i.addr(15 downto 2)));

        -- WRITE
        if bus_req_i.rw = '1' then
          if bus_req_i.ben = "1111" then

            if reg_idx = REG_CTRL then
              if bus_req_i.data(0) = '1' then
                clear_pulse <= '1';
              end if;
              if bus_req_i.data(1) = '1' then
                start_pulse <= '1';
              end if;

            elsif reg_idx = REG_COUNT then
              count_u <= unsigned(bus_req_i.data);

            -- settings
            elsif reg_idx = REG_LAMBDA then
              lambda_u <= unsigned(bus_req_i.data);
            elsif reg_idx = REG_A_MAX then
              amax_u <= unsigned(bus_req_i.data);
            elsif reg_idx = REG_EPS_B then
              eps_b_q16 <= unsigned(bus_req_i.data(15 downto 0));
            elsif reg_idx = REG_EPS_N then
              eps_n_q16 <= unsigned(bus_req_i.data(15 downto 0));
            elsif reg_idx = REG_ALPHA then
              alpha_q16 <= unsigned(bus_req_i.data(15 downto 0));
            elsif reg_idx = REG_D then
              d_q16 <= unsigned(bus_req_i.data(15 downto 0));

            -- winner inputs
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

            -- dataset
            elsif (reg_idx >= DATA_BASE) and (reg_idx < DATA_BASE + MAXPTS) then
              di := reg_idx - DATA_BASE;
              data_mem(di) <= bus_req_i.data;

            -- nodes
            elsif (reg_idx >= NODE_BASE) and (reg_idx < NODE_BASE + MAXNODES) then
              di := reg_idx - NODE_BASE;
              node_mem(di) <= bus_req_i.data;

            -- edges (NEW)
            elsif (reg_idx >= EDGE_BASE) and (reg_idx < EDGE_BASE + MAXEDGES) then
              di := reg_idx - EDGE_BASE;
              edge_mem(di) <= bus_req_i.data;

            end if;
          end if;

        -- READ
        else
          if reg_idx = REG_CTRL then
            bus_rsp_o.data(16) <= busy;
            bus_rsp_o.data(17) <= done;

          elsif reg_idx = REG_COUNT then
            bus_rsp_o.data <= std_ulogic_vector(count_u);

          -- settings
          elsif reg_idx = REG_LAMBDA then
            bus_rsp_o.data <= std_ulogic_vector(lambda_u);
          elsif reg_idx = REG_A_MAX then
            bus_rsp_o.data <= std_ulogic_vector(amax_u);
          elsif reg_idx = REG_EPS_B then
            bus_rsp_o.data(15 downto 0) <= std_ulogic_vector(eps_b_q16);
          elsif reg_idx = REG_EPS_N then
            bus_rsp_o.data(15 downto 0) <= std_ulogic_vector(eps_n_q16);
          elsif reg_idx = REG_ALPHA then
            bus_rsp_o.data(15 downto 0) <= std_ulogic_vector(alpha_q16);
          elsif reg_idx = REG_D then
            bus_rsp_o.data(15 downto 0) <= std_ulogic_vector(d_q16);

          -- winner inputs readback
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

          -- winner outputs
          elsif reg_idx = REG_OUT_S12 then
            bus_rsp_o.data(7 downto 0)  <= std_ulogic_vector(out_s1);
            bus_rsp_o.data(15 downto 8) <= std_ulogic_vector(out_s2);
          elsif reg_idx = REG_OUT_MIN1 then
            bus_rsp_o.data <= std_ulogic_vector(out_min1);
          elsif reg_idx = REG_OUT_MIN2 then
            bus_rsp_o.data <= std_ulogic_vector(out_min2);

          -- dataset read
          elsif (reg_idx >= DATA_BASE) and (reg_idx < DATA_BASE + MAXPTS) then
            di := reg_idx - DATA_BASE;
            bus_rsp_o.data <= data_mem(di);

          -- node mem read
          elsif (reg_idx >= NODE_BASE) and (reg_idx < NODE_BASE + MAXNODES) then
            di := reg_idx - NODE_BASE;
            bus_rsp_o.data <= node_mem(di);

          -- edge mem read (NEW)
          elsif (reg_idx >= EDGE_BASE) and (reg_idx < EDGE_BASE + MAXEDGES) then
            di := reg_idx - EDGE_BASE;
            bus_rsp_o.data <= edge_mem(di);

          else
            bus_rsp_o.data <= (others => '0');
          end if;

        end if;
      end if;
    end if;
  end process;

end architecture;
