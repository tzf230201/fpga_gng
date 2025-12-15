-- ================================================================================ --
-- NEORV32 SoC - Custom Functions Subsystem (CFS)                                   --
-- ================================================================================ --

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

  constant MAXPTS    : natural := 100;
  constant DATA_BASE : natural := 16;

  type data_mem_t is array (0 to MAXPTS-1) of std_ulogic_vector(31 downto 0);
  -- NOTE: no init here to avoid big reset/clear structures
  signal data_mem : data_mem_t;

  signal count_u  : unsigned(31 downto 0) := (others => '0');
  signal busy     : std_ulogic := '0';
  signal done     : std_ulogic := '0';

  -- GNG settings (defaults)
  signal lambda_u  : unsigned(31 downto 0) := to_unsigned(100, 32);
  signal amax_u    : unsigned(31 downto 0) := to_unsigned(50,  32);

  signal eps_b_q16 : unsigned(15 downto 0) := to_unsigned(19661, 16);
  signal eps_n_q16 : unsigned(15 downto 0) := to_unsigned(65,    16);
  signal alpha_q16 : unsigned(15 downto 0) := to_unsigned(32768, 16);
  signal d_q16     : unsigned(15 downto 0) := to_unsigned(65101, 16);

begin

  cfs_out_o <= (others => '0');
  irq_o     <= '0';

  bus_access: process(rstn_i, clk_i)
    variable reg_idx : natural;
    variable di      : natural;
  begin
    if (rstn_i = '0') then
      -- IMPORTANT: do NOT reset/clear data_mem (huge FF reset network)
      count_u   <= (others => '0');
      busy      <= '0';
      done      <= '0';
      bus_rsp_o <= rsp_terminate_c;

    elsif rising_edge(clk_i) then
      -- default response
      bus_rsp_o.ack  <= bus_req_i.stb;
      bus_rsp_o.err  <= '0';
      bus_rsp_o.data <= (others => '0');

      if (bus_req_i.stb = '1') then
        reg_idx := to_integer(unsigned(bus_req_i.addr(15 downto 2)));

        -- WRITE
        if (bus_req_i.rw = '1') then
          if (bus_req_i.ben = "1111") then

            if reg_idx = 0 then
              -- CTRL: bit0=CLEAR, bit1=START
              if bus_req_i.data(0) = '1' then
                -- NO mass clear of data_mem
                count_u <= (others => '0');
                done    <= '0';
                busy    <= '0';
              end if;

              if bus_req_i.data(1) = '1' then
                -- placeholder start
                done <= '1';
                busy <= '0';
              end if;

            elsif reg_idx = 1 then
              count_u <= unsigned(bus_req_i.data);

            elsif reg_idx = 2 then
              lambda_u <= unsigned(bus_req_i.data);

            elsif reg_idx = 3 then
              amax_u <= unsigned(bus_req_i.data);

            elsif reg_idx = 4 then
              eps_b_q16 <= unsigned(bus_req_i.data(15 downto 0));

            elsif reg_idx = 5 then
              eps_n_q16 <= unsigned(bus_req_i.data(15 downto 0));

            elsif reg_idx = 6 then
              alpha_q16 <= unsigned(bus_req_i.data(15 downto 0));

            elsif reg_idx = 7 then
              d_q16 <= unsigned(bus_req_i.data(15 downto 0));

            elsif (reg_idx >= DATA_BASE) and (reg_idx < DATA_BASE + MAXPTS) then
              di := reg_idx - DATA_BASE;
              data_mem(di) <= bus_req_i.data;
            end if;

          end if;

        -- READ
        else
          if reg_idx = 0 then
            bus_rsp_o.data(16) <= busy;
            bus_rsp_o.data(17) <= done;

          elsif reg_idx = 1 then
            bus_rsp_o.data <= std_ulogic_vector(count_u);

          elsif reg_idx = 2 then
            bus_rsp_o.data <= std_ulogic_vector(lambda_u);

          elsif reg_idx = 3 then
            bus_rsp_o.data <= std_ulogic_vector(amax_u);

          elsif reg_idx = 4 then
            bus_rsp_o.data(15 downto 0) <= std_ulogic_vector(eps_b_q16);

          elsif reg_idx = 5 then
            bus_rsp_o.data(15 downto 0) <= std_ulogic_vector(eps_n_q16);

          elsif reg_idx = 6 then
            bus_rsp_o.data(15 downto 0) <= std_ulogic_vector(alpha_q16);

          elsif reg_idx = 7 then
            bus_rsp_o.data(15 downto 0) <= std_ulogic_vector(d_q16);

          elsif (reg_idx >= DATA_BASE) and (reg_idx < DATA_BASE + MAXPTS) then
            di := reg_idx - DATA_BASE;
            bus_rsp_o.data <= data_mem(di);

          else
            bus_rsp_o.data <= (others => '0');
          end if;
        end if;

      end if;
    end if;
  end process;

end architecture;
