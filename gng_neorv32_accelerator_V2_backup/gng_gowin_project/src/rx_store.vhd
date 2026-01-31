library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rx_store_ext is
  generic (
    DEPTH : natural := 400
  );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic; -- active-low

    -- from UART RX
    rx_valid_i : in  std_logic; -- pulse/level ok
    rx_data_i  : in  std_logic_vector(7 downto 0);

    -- optional external hold
    hold_i     : in  std_logic := '0';

    -- clear lock after send done
    clear_i    : in  std_logic := '0';

    -- pulse 1 clk when filled DEPTH bytes
    full_o     : out std_logic;

    -- memory interface OUT (WRITE PORT)  <<< REGISTERED + ALIGNED >>>
    mem_we_o    : out std_logic;
    mem_waddr_o : out unsigned(8 downto 0);
    mem_wdata_o : out std_logic_vector(7 downto 0);

    -- memory interface IN (READ PORT)
    mem_raddr_i : in  unsigned(8 downto 0);
    mem_rdata_i : in  std_logic_vector(7 downto 0);

    -- optional read-out (registered)
    rdata_o    : out std_logic_vector(7 downto 0);

    locked_o   : out std_logic
  );
end entity;

architecture rtl of rx_store_ext is
  constant PTR_W : natural := 9;

  signal wr_idx : unsigned(PTR_W-1 downto 0) := (others => '0');

  -- edge detect rx_valid_i
  signal v_d : std_logic := '0';
  signal v_p : std_logic := '0';

  signal full   : std_logic := '0';
  signal locked : std_logic := '0';

  -- registered read-out
  signal rdata_reg : std_logic_vector(7 downto 0) := (others => '0');

  -- REGISTERED write outputs (the fix)
  signal we_r    : std_logic := '0';
  signal waddr_r : unsigned(PTR_W-1 downto 0) := (others => '0');
  signal wdata_r : std_logic_vector(7 downto 0) := (others => '0');

begin
  full_o   <= full;
  locked_o <= locked;
  rdata_o  <= rdata_reg;

  mem_we_o    <= we_r;
  mem_waddr_o <= waddr_r;
  mem_wdata_o <= wdata_r;

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      -- defaults
      full  <= '0';
      we_r  <= '0';

      -- edge detect
      v_p <= rx_valid_i and (not v_d);
      v_d <= rx_valid_i;

      if rstn_i = '0' then
        wr_idx    <= (others => '0');
        v_d       <= '0';
        v_p       <= '0';
        locked    <= '0';
        rdata_reg <= (others => '0');

        we_r      <= '0';
        waddr_r   <= (others => '0');
        wdata_r   <= (others => '0');

      else
        -- registered read
        rdata_reg <= mem_rdata_i;

        -- unlock
        if clear_i = '1' then
          locked <= '0';
        end if;

        -- schedule write only when not locked/hold
        if (locked = '0') and (hold_i = '0') and (v_p = '1') then
          -- >>> FIX: register addr+data+we together <<<
          waddr_r <= wr_idx;
          wdata_r <= rx_data_i;
          we_r    <= '1';

          if wr_idx = to_unsigned(DEPTH-1, PTR_W) then
            full   <= '1';
            locked <= '1';
            wr_idx <= (others => '0');
          else
            wr_idx <= wr_idx + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture;
