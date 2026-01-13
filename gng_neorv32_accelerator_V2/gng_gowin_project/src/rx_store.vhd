library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rx_store is
  generic (
    DEPTH : natural := 400
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic; -- active-low

    -- from UART RX
    rx_valid_i : in  std_logic; -- pulse/level ok
    rx_data_i  : in  std_logic_vector(7 downto 0);

    -- optional external hold (redundant, but keep)
    hold_i     : in  std_logic := '0';

    -- clear lock after send done
    clear_i    : in  std_logic := '0';

    -- pulse 1 clk when filled DEPTH bytes
    full_o     : out std_logic;

    -- read port for copy module (SYNC read 1-cycle)
    raddr_i    : in  unsigned(8 downto 0);
    rdata_o    : out std_logic_vector(7 downto 0);

    locked_o   : out std_logic
  );
end entity;

architecture rtl of rx_store is
  constant PTR_W : natural := 9;

  type mem_t is array (0 to DEPTH-1) of std_logic_vector(7 downto 0);
  signal mem : mem_t;

  signal wr_idx : unsigned(PTR_W-1 downto 0) := (others => '0');

  -- edge detect rx_valid_i
  signal v_d : std_logic := '0';
  signal v_p : std_logic := '0';

  signal full   : std_logic := '0';
  signal locked : std_logic := '0';

  -- sync read reg
  signal rdata_reg : std_logic_vector(7 downto 0) := (others => '0');

begin
  full_o   <= full;
  rdata_o  <= rdata_reg;
  locked_o <= locked;

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      full <= '0';

      -- edge detect
      v_p <= rx_valid_i and (not v_d);
      v_d <= rx_valid_i;

      if rstn_i = '0' then
        wr_idx    <= (others => '0');
        v_d       <= '0';
        v_p       <= '0';
        rdata_reg <= (others => '0');
        locked    <= '0';

      else
        -- SYNC READ (1-cycle)
        rdata_reg <= mem(to_integer(raddr_i));

        -- unlock if requested
        if clear_i = '1' then
          locked <= '0';
        end if;

        -- WRITE only when not locked/hold
        if (locked = '0') and (hold_i = '0') and (v_p = '1') then
          mem(to_integer(wr_idx)) <= rx_data_i;

          if wr_idx = to_unsigned(DEPTH-1, PTR_W) then
            full   <= '1';
            locked <= '1';              -- lock immediately after full
            wr_idx <= (others => '0');  -- prepare next batch
          else
            wr_idx <= wr_idx + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture;
