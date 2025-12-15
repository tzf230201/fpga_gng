-- ================================================================================ --
-- NEORV32 SoC - Custom Functions Subsystem (CFS)                                   --
-- -------------------------------------------------------------------------------- --
-- The NEORV32 RISC-V Processor - https://github.com/stnolting/neorv32              --
-- Copyright (c) NEORV32 contributors.                                              --
-- Copyright (c) 2020 - 2025 Stephan Nolting. All rights reserved.                  --
-- Licensed under the BSD-3-Clause license, see LICENSE for details.                --
-- SPDX-License-Identifier: BSD-3-Clause                                            --
-- ================================================================================ --

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;

entity neorv32_cfs is
  port (
    -- global control --
    clk_i     : in  std_ulogic; -- global clock line
    rstn_i    : in  std_ulogic; -- global reset line, low-active, async
    -- CPU access --
    bus_req_i : in  bus_req_t; -- bus request
    bus_rsp_o : out bus_rsp_t; -- bus response
    -- CPU interrupt --
    irq_o     : out std_ulogic; -- interrupt request
    -- external IO --
    cfs_in_i  : in  std_ulogic_vector(255 downto 0); -- custom inputs conduit
    cfs_out_o : out std_ulogic_vector(255 downto 0) -- custom outputs conduit
  );
end neorv32_cfs;

architecture neorv32_cfs_rtl of neorv32_cfs is

  constant MAXPTS    : natural := 100;
  constant DATA_BASE : natural := 16; -- word index (REG[16]..)

  type data_mem_t is array (0 to MAXPTS-1) of std_ulogic_vector(31 downto 0);
  signal data_mem : data_mem_t := (others => (others => '0'));

  signal count_u  : unsigned(31 downto 0) := (others => '0');
  signal busy     : std_ulogic := '0';
  signal done     : std_ulogic := '0';

begin

  cfs_out_o <= (others => '0'); -- unused for now
  irq_o     <= '0';             -- unused for now

  bus_access: process(rstn_i, clk_i)
    variable reg_idx : natural;
    variable di      : natural;
  begin
    if (rstn_i = '0') then
      for i in 0 to MAXPTS-1 loop
        data_mem(i) <= (others => '0');
      end loop;
      count_u  <= (others => '0');
      busy     <= '0';
      done     <= '0';
      bus_rsp_o <= rsp_terminate_c;

    elsif rising_edge(clk_i) then
      -- default response
      bus_rsp_o.ack  <= bus_req_i.stb; -- ACK 1 cycle after request (registered)
      bus_rsp_o.err  <= '0';
      bus_rsp_o.data <= (others => '0');

      if (bus_req_i.stb = '1') then
        reg_idx := to_integer(unsigned(bus_req_i.addr(15 downto 2))); -- word index

        -- WRITE
        if (bus_req_i.rw = '1') then
          -- optional: only accept full-word writes
          if (bus_req_i.ben = "1111") then
            if reg_idx = 0 then
              -- CTRL: bit0=CLEAR, bit1=START (future)
              if bus_req_i.data(0) = '1' then
                for i in 0 to MAXPTS-1 loop
                  data_mem(i) <= (others => '0');
                end loop;
                count_u <= (others => '0');
                done    <= '0';
                busy    <= '0';
              end if;

              if bus_req_i.data(1) = '1' then
                -- placeholder "start": langsung DONE (nanti diganti jadi winner finder)
                done <= '1';
                busy <= '0';
              end if;

            elsif reg_idx = 1 then
              count_u <= unsigned(bus_req_i.data);

            elsif (reg_idx >= DATA_BASE) and (reg_idx < DATA_BASE + MAXPTS) then
              di := reg_idx - DATA_BASE;
              data_mem(di) <= bus_req_i.data;
            end if;
          end if;

        -- READ
        else
          if reg_idx = 0 then
            -- STATUS
            bus_rsp_o.data(16) <= busy;
            bus_rsp_o.data(17) <= done;
          elsif reg_idx = 1 then
            bus_rsp_o.data <= std_ulogic_vector(count_u);
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
