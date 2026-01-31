library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bram_copy is
  generic ( DEPTH : natural := 400 );
  port (
    clk_i   : in  std_logic;
    rstn_i  : in  std_logic;
    start_i : in  std_logic; -- pulse/level ok

    -- BRAM_A read (sync 1-cycle from rx_store)
    a_raddr_o : out unsigned(8 downto 0);
    a_rdata_i : in  std_logic_vector(7 downto 0);

    -- BRAM_B write (REGISTERED outputs!)
    b_waddr_o : out unsigned(8 downto 0);
    b_wdata_o : out std_logic_vector(7 downto 0);
    b_we_o    : out std_logic;

    done_o    : out std_logic; -- level done
    busy_o    : out std_logic
  );
end entity;

architecture rtl of bram_copy is
  constant PTR_W : natural := 9;

  type st_t is (IDLE, SET_ADDR, WAIT_RD, WRITE_PULSE, ADV, DONE);
  signal st : st_t := IDLE;

  signal idx : unsigned(PTR_W-1 downto 0) := (others => '0');

  -- edge detect start (internal, biar aman kalau start_i level)
  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  -- registered write signals
  signal we_r    : std_logic := '0';
  signal waddr_r : unsigned(PTR_W-1 downto 0) := (others => '0');
  signal wdata_r : std_logic_vector(7 downto 0) := (others => '0');
begin
  a_raddr_o <= idx;

  b_we_o    <= we_r;
  b_waddr_o <= waddr_r;
  b_wdata_o <= wdata_r;

  busy_o <= '1' when (st /= IDLE) else '0';

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      -- default
      we_r   <= '0';
      start_p <= start_i and (not start_d);
      start_d <= start_i;

      if rstn_i = '0' then
        st      <= IDLE;
        idx     <= (others => '0');
        done_o  <= '0';
        start_d <= '0';
        start_p <= '0';
        we_r    <= '0';
        waddr_r <= (others => '0');
        wdata_r <= (others => '0');

      else
        case st is
          when IDLE =>
            done_o <= '0';
            if start_p = '1' then
              idx <= (others => '0');
              st  <= SET_ADDR;
            end if;

          when SET_ADDR =>
            -- addr already driven by idx
            st <= WAIT_RD;

          when WAIT_RD =>
            -- wait 1 cycle for a_rdata_i valid
            st <= WRITE_PULSE;

          when WRITE_PULSE =>
            -- REGISTER addr+data+we in the SAME cycle (stable for full next cycle)
            waddr_r <= idx;
            wdata_r <= a_rdata_i;
            we_r    <= '1';
            st      <= ADV;

          when ADV =>
            if idx = to_unsigned(DEPTH-1, PTR_W) then
              st <= DONE;
            else
              idx <= idx + 1;
              st  <= SET_ADDR;
            end if;

          when DONE =>
            done_o <= '1';        -- level
            -- tunggu start_i turun supaya tidak retrigger
            if start_i = '0' then
              st <= IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;
end architecture;
