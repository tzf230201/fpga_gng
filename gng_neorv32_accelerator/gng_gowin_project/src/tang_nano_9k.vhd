-- ================================================================================ --
-- NEORV32 Templates - Minimal generic setup with the bootloader enabled            --
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

entity neorv32_ProcessorTop_MinimalBoot is
  generic (
    -- Clocking --
    
    CLOCK_FREQUENCY : natural := 27000000;       -- clock frequency of clk_i in Hz
    -- Internal Instruction memory --
    IMEM_EN         : boolean := false;    -- implement processor-internal instruction memory --default true
    IMEM_SIZE       : natural := 0*1024; -- size of processor-internal instruction memory in bytes --default 64
    -- Internal Data memory --
    DMEM_EN         : boolean := true;    -- implement processor-internal data memory
    DMEM_SIZE       : natural := 16*1024; -- size of processor-internal data memory in bytes --default 64
    -- Processor peripherals --
    IO_GPIO_NUM     : natural := 6;       -- number of GPIO input/output pairs (0..32)

    BOOT_MODE_SELECT : natural := 0;
    UFLASH_BASE : std_logic_vector(31 downto 0) := x"00000000";
    UFLASH_END : std_logic_vector(31 downto 0) :=  x"00013000" -- 38 pages * 2048 bytes
  );
  port (
    -- Global control --
    clk_i      : in  std_logic;
    rstn_i     : in  std_logic;
    -- GPIO (available if IO_GPIO_EN = true) --
    gpio_o     : out std_ulogic_vector(IO_GPIO_NUM-1 downto 0);
    -- primary UART0 (available if IO_UART0_EN = true) --
    uart_txd_o : out std_ulogic; -- UART0 send data
    uart_rxd_i : in  std_ulogic := '0'; -- UART0 receive data
    -- PWM (available if IO_PWM_NUM > 0) --
--    pwm_o      : out std_ulogic_vector(IO_PWM_NUM-1 downto 0)
    -- JTAG --
    jtag_tck_i     : in  std_ulogic;                                 -- serial clock
    jtag_tdi_i     : in  std_ulogic;                                 -- serial data input
    jtag_tdo_o     : out std_ulogic;                                 -- serial data output
    jtag_tms_i     : in  std_ulogic 
  );
end entity;

architecture neorv32_ProcessorTop_MinimalBoot_rtl of neorv32_ProcessorTop_MinimalBoot is

  -- internal IO connection --
--  signal con_gpio_o, con_pwm_o : std_ulogic_vector(31 downto 0);
  signal con_gpio_o : std_ulogic_vector(31 downto 0);

   --Xbus signals
  signal xbus_adr_o : std_ulogic_vector(31 downto 0);
  signal xbus_dat_o : std_ulogic_vector(31 downto 0);
  signal xbus_tag_o : std_ulogic_vector(2 downto 0);
  signal xbus_we_o : std_ulogic;
  signal xbus_sel_o : std_ulogic_vector(3 downto 0);
  signal xbus_stb_o : std_ulogic;
  signal xbus_cyc_o : std_ulogic;
  signal xbus_dat_i : std_ulogic_vector(31 downto 0);
  signal xbus_ack_i : std_ulogic;
  signal xbus_err_i : std_ulogic;

   --Xbus interconnect
  signal sel_uflash    : std_logic := '0';


   --Slave A signals
  signal uflash_ack_i : std_ulogic;
  signal uflash_err_i : std_ulogic := '0';
  signal uflash_dat_i : std_ulogic_vector(31 downto 0);

  signal cfs_in_i_r       : std_ulogic_vector(255 downto 0);
  signal cfs_out_o_r      : std_ulogic_vector(255 downto 0);

begin

   --Check if address is in uflash range
  sel_uflash <= '1' when (
      (unsigned(xbus_adr_o) >= unsigned(UFLASH_BASE)) and
      (unsigned(xbus_adr_o) < unsigned(UFLASH_END))
      ) else '0';

  -- Connect the Xbus signals to the selected slave, or default to err if no slave is selected
  xbus_ack_i <= uflash_ack_i when (sel_uflash = '1') else
             '1';

  xbus_err_i <= uflash_err_i when (sel_uflash = '1') else
             '1'; -- default to err if no slave is selected

  xbus_dat_i <= uflash_dat_i when (sel_uflash = '1') else
             x"deadbeef"; -- default to 0 if no slave is selected

  uflash_inst: entity work.uflash
  generic map (
    CLK_FREQ => CLOCK_FREQUENCY
  )
  port map (
    reset_n => rstn_i,
    clk => clk_i,
    wb_cyc_i => xbus_cyc_o,
    wb_stb_i => xbus_stb_o,
    wb_we_i => xbus_we_o,
    wb_sel_i => xbus_sel_o,
    wb_adr_i => xbus_adr_o(16 downto 2),
    wb_dat_o => uflash_dat_i,
    wb_dat_i => xbus_dat_o,
    wb_ack_o => uflash_ack_i,
    wb_err_o => uflash_err_i
  );

  -- The core of the problem ----------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  neorv32_inst: entity neorv32.neorv32_top
  generic map (
    -- Clocking --
    CLOCK_FREQUENCY  => CLOCK_FREQUENCY, -- clock frequency of clk_i in Hz
    -- Boot Configuration --
    BOOT_MODE_SELECT => BOOT_MODE_SELECT,               -- boot via internal bootloader
    -- RISC-V CPU Extensions --
    RISCV_ISA_Zicntr => true,            -- implement base counters?
    -- Internal Instruction memory --
    IMEM_EN          => IMEM_EN,         -- implement processor-internal instruction memory
    IMEM_SIZE        => IMEM_SIZE,       -- size of processor-internal instruction memory in bytes
    -- Internal Data memory --
    DMEM_EN          => DMEM_EN,         -- implement processor-internal data memory
    DMEM_SIZE        => DMEM_SIZE,       -- size of processor-internal data memory in bytes
    -- Processor peripherals --
    IO_GPIO_NUM      => IO_GPIO_NUM,     -- number of GPIO input/output pairs (0..32)
    IO_CLINT_EN      => true,            -- implement core local interruptor (CLINT)?
    IO_UART0_EN      => true,            -- implement primary universal asynchronous receiver/transmitter (UART0)?
    OCD_EN            => true,               -- implement JTAG interface

    IO_CFS_EN       => true,

    XBUS_EN           => true,              -- implement X-Bus interface
    XBUS_TIMEOUT      => 0                  -- Disable timeout, flash erase can take a long time
  )
  port map (
    -- Global control --
    clk_i       => clk_i,                        -- global clock, rising edge
    rstn_i      => rstn_i,                       -- global reset, low-active, async
    -- GPIO (available if IO_GPIO_NUM > 0) --
    gpio_o      => con_gpio_o,                   -- parallel output
    gpio_i      => (others => '0'),              -- parallel input
    -- primary UART0 (available if IO_UART0_EN = true) --
    uart0_txd_o => uart_txd_o,                   -- UART0 send data
    uart0_rxd_i => uart_rxd_i,                   -- UART0 receive data
    -- PWM (available if IO_PWM_NUM > 0) --
--    pwm_o       => con_pwm_o                     -- pwm channels

    cfs_in_i => cfs_in_i_r,
    cfs_out_o => cfs_out_o_r,

-- JTAG (available if IO_JTAG_EN = true) --
    jtag_tck_i => jtag_tck_i,                                 -- serial clock
    jtag_tdi_i => jtag_tdi_i,                                 -- serial data input
    jtag_tdo_o => jtag_tdo_o,                                 -- serial data output
    jtag_tms_i => jtag_tms_i,                                 -- mode select

    -- Xbus signals
    xbus_adr_o => xbus_adr_o,
    xbus_dat_o => xbus_dat_o,
    xbus_tag_o => xbus_tag_o,
    xbus_we_o => xbus_we_o,
    xbus_sel_o => xbus_sel_o,
    xbus_stb_o => xbus_stb_o,
    xbus_cyc_o => xbus_cyc_o,
    xbus_dat_i => xbus_dat_i,
    xbus_ack_i => xbus_ack_i,
    xbus_err_i => xbus_err_i

  );

  -- GPIO --
  gpio_o <= con_gpio_o(IO_GPIO_NUM-1 downto 0);

  -- PWM --
--  pwm_o <= con_pwm_o(IO_PWM_NUM-1 downto 0);


end architecture;