library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng_dump_state_uart_sumchk is
  generic (
    MAX_NODES : natural := 40;
    MAX_DEG   : natural := 6
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in std_logic;

    -- debug memories (sync 1-cycle read)
    node_raddr_o : out unsigned(5 downto 0);
    node_rdata_i : in  std_logic_vector(31 downto 0);

    err_raddr_o  : out unsigned(5 downto 0);
    err_rdata_i  : in  std_logic_vector(31 downto 0); -- bit31=active

    edge_raddr_o : out unsigned(8 downto 0);          -- 9-bit (match dbg port)
    edge_rdata_i : in  std_logic_vector(15 downto 0);

    -- UART TX handshake
    tx_busy_i  : in  std_logic;
    tx_done_i  : in  std_logic;
    tx_start_o : out std_logic;
    tx_data_o  : out std_logic_vector(7 downto 0);

    done_o : out std_logic;  -- == SEND_DONE pulse 1 clk
    busy_o : out std_logic
  );
end entity;

architecture rtl of gng_dump_state_uart_sumchk is

  function clog2(n : natural) return natural is
    variable r : natural := 0;
    variable v : natural := 1;
  begin
    while v < n loop
      v := v * 2;
      r := r + 1;
    end loop;
    return r;
  end function;

  constant NODE_AW      : natural := clog2(MAX_NODES); -- 6 for 40
  constant EDGE_DEPTH   : natural := MAX_NODES * MAX_DEG; -- 240
  constant EDGE_AW_PORT : natural := 9; -- force 9-bit

  constant GNG_MASK_BYTES : natural := 8;

  -- payload:
  -- [0]   : 0xA1
  -- [1:2] : step counter u16 LE (di versi ini = 0)
  -- [3]   : nodeN (=MAX_NODES)
  -- [4]   : degN  (=MAX_DEG)
  -- [5..12] : active mask 8 bytes (LSB=node0)
  -- then  : MAX_NODES * 4 bytes node words (little-endian)
  -- then  : EDGE_DEPTH * 2 bytes edge halfwords (little-endian)
  constant PAYLOAD_BYTES : natural :=
    1 + 2 + 1 + 1 + GNG_MASK_BYTES + (MAX_NODES*4) + (EDGE_DEPTH*2);

  type st_t is (
    IDLE,

    SEND_FF1, WAIT_FF1,
    SEND_FF2, WAIT_FF2,
    SEND_LEN0, WAIT_LEN0,
    SEND_LEN1, WAIT_LEN1,
    SEND_SEQ,  WAIT_SEQ,

    -- build mask from err_mem
    MASK_CLR,
    MASK_SET, MASK_WAIT, MASK_LATCH,

    -- payload header
    SEND_MAGIC, WAIT_MAGIC,
    SEND_STEP0, WAIT_STEP0,
    SEND_STEP1, WAIT_STEP1,
    SEND_NODEN, WAIT_NODEN,
    SEND_DEGN,  WAIT_DEGN,

    -- mask bytes
    SEND_M0, WAIT_M0,
    SEND_M1, WAIT_M1,
    SEND_M2, WAIT_M2,
    SEND_M3, WAIT_M3,
    SEND_M4, WAIT_M4,
    SEND_M5, WAIT_M5,
    SEND_M6, WAIT_M6,
    SEND_M7, WAIT_M7,

    -- nodes
    RD_NODE_SET, RD_NODE_WAIT, RD_NODE_LATCH,
    SEND_N0, WAIT_N0,
    SEND_N1, WAIT_N1,
    SEND_N2, WAIT_N2,
    SEND_N3, WAIT_N3,

    -- edges
    RD_EDGE_SET, RD_EDGE_WAIT, RD_EDGE_LATCH,
    SEND_E0, WAIT_E0,
    SEND_E1, WAIT_E1,

    -- checksum
    SEND_CHK, WAIT_CHK,
    FINISH
  );

  signal st : st_t := IDLE;

  signal seq      : unsigned(7 downto 0)  := (others => '0');
  signal chk      : unsigned(7 downto 0)  := (others => '0');

  -- step counter dikirim, tapi di versi ini selalu 0
  constant step_cnt : unsigned(15 downto 0) := (others => '0');

  signal node_idx : unsigned(NODE_AW-1 downto 0) := (others => '0');
  signal node_reg : std_logic_vector(31 downto 0) := (others => '0');

  signal edge_idx : unsigned(EDGE_AW_PORT-1 downto 0) := (others => '0');
  signal edge_reg : std_logic_vector(15 downto 0) := (others => '0');

  -- mask build
  type mask_arr_t is array(0 to 7) of std_logic_vector(7 downto 0);
  signal mask_arr : mask_arr_t := (others => (others => '0'));
  signal mask_idx : unsigned(NODE_AW-1 downto 0) := (others => '0');

  signal node_raddr_s : unsigned(NODE_AW-1 downto 0) := (others => '0');
  signal err_raddr_s  : unsigned(NODE_AW-1 downto 0) := (others => '0');
  signal edge_raddr_s : unsigned(EDGE_AW_PORT-1 downto 0) := (others => '0');

  -- start edge detect
  signal start_d     : std_logic := '0';
  signal start_pulse : std_logic := '0';

  function lo8(v : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(v, 16)(7 downto 0));
  end function;

  function hi8(v : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(v, 16)(15 downto 8));
  end function;

begin
  node_raddr_o <= node_raddr_s;
  err_raddr_o  <= err_raddr_s;
  edge_raddr_o <= edge_raddr_s;

  -- start rising-edge detector
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        start_d     <= '0';
        start_pulse <= '0';
      else
        start_pulse <= start_i and (not start_d);
        start_d     <= start_i;
      end if;
    end if;
  end process;

  process(clk_i)
    procedure kick_send(b : std_logic_vector(7 downto 0)) is
    begin
      tx_data_o  <= b;
      tx_start_o <= '1';
    end procedure;

    procedure add_chk(b : std_logic_vector(7 downto 0)) is
    begin
      chk <= chk + unsigned(b);
    end procedure;

    variable bi : integer;
    variable bj : integer;
  begin
    if rising_edge(clk_i) then
      tx_start_o <= '0';
      done_o     <= '0';

      if rstn_i = '0' then
        st  <= IDLE;
        seq <= (others => '0');
        chk <= (others => '0');

        node_idx <= (others => '0');
        edge_idx <= (others => '0');
        mask_idx <= (others => '0');

        node_raddr_s <= (others => '0');
        err_raddr_s  <= (others => '0');
        edge_raddr_s <= (others => '0');

        mask_arr <= (others => (others => '0'));

      else
        case st is

          when IDLE =>
            if start_pulse = '1' then
              st <= SEND_FF1;
            end if;

          when SEND_FF1 =>
            if tx_busy_i = '0' then
              kick_send(x"FF");
              st <= WAIT_FF1;
            end if;

          when WAIT_FF1 =>
            if tx_done_i = '1' then st <= SEND_FF2; end if;

          when SEND_FF2 =>
            if tx_busy_i = '0' then
              kick_send(x"FF");
              st <= WAIT_FF2;
            end if;

          when WAIT_FF2 =>
            if tx_done_i = '1' then st <= SEND_LEN0; end if;

          when SEND_LEN0 =>
            if tx_busy_i = '0' then
              kick_send(lo8(PAYLOAD_BYTES));
              st <= WAIT_LEN0;
            end if;

          when WAIT_LEN0 =>
            if tx_done_i = '1' then st <= SEND_LEN1; end if;

          when SEND_LEN1 =>
            if tx_busy_i = '0' then
              kick_send(hi8(PAYLOAD_BYTES));
              st <= WAIT_LEN1;
            end if;

          when WAIT_LEN1 =>
            if tx_done_i = '1' then st <= SEND_SEQ; end if;

          when SEND_SEQ =>
            if tx_busy_i = '0' then
              kick_send(std_logic_vector(seq));
              chk      <= (others => '0'); -- checksum untuk payload saja
              node_idx <= (others => '0');
              edge_idx <= (others => '0');
              mask_idx <= (others => '0');
              st       <= WAIT_SEQ;
            end if;

          when WAIT_SEQ =>
            if tx_done_i = '1' then st <= MASK_CLR; end if;

          -- ==========================
          -- build active mask
          -- ==========================
          when MASK_CLR =>
            mask_arr <= (others => (others => '0'));
            mask_idx <= (others => '0');
            st <= MASK_SET;

          when MASK_SET =>
            err_raddr_s <= mask_idx;
            st <= MASK_WAIT;

          when MASK_WAIT =>
            st <= MASK_LATCH;

          when MASK_LATCH =>
            if err_rdata_i(31) = '1' then
              bi := to_integer(mask_idx) / 8;
              bj := to_integer(mask_idx) mod 8;
              if (bi >= 0) and (bi <= 7) then
                mask_arr(bi)(bj) <= '1';
              end if;
            end if;

            if mask_idx = to_unsigned(MAX_NODES-1, mask_idx'length) then
              st <= SEND_MAGIC;
            else
              mask_idx <= mask_idx + 1;
              st <= MASK_SET;
            end if;

          -- ==========================
          -- payload header
          -- ==========================
          when SEND_MAGIC =>
            if tx_busy_i = '0' then
              kick_send(x"A1"); add_chk(x"A1");
              st <= WAIT_MAGIC;
            end if;

          when WAIT_MAGIC =>
            if tx_done_i = '1' then st <= SEND_STEP0; end if;

          when SEND_STEP0 =>
            if tx_busy_i = '0' then
              kick_send(std_logic_vector(step_cnt(7 downto 0)));
              add_chk(std_logic_vector(step_cnt(7 downto 0)));
              st <= WAIT_STEP0;
            end if;

          when WAIT_STEP0 =>
            if tx_done_i = '1' then st <= SEND_STEP1; end if;

          when SEND_STEP1 =>
            if tx_busy_i = '0' then
              kick_send(std_logic_vector(step_cnt(15 downto 8)));
              add_chk(std_logic_vector(step_cnt(15 downto 8)));
              st <= WAIT_STEP1;
            end if;

          when WAIT_STEP1 =>
            if tx_done_i = '1' then st <= SEND_NODEN; end if;

          when SEND_NODEN =>
            if tx_busy_i = '0' then
              kick_send(std_logic_vector(to_unsigned(MAX_NODES, 8)));
              add_chk(std_logic_vector(to_unsigned(MAX_NODES, 8)));
              st <= WAIT_NODEN;
            end if;

          when WAIT_NODEN =>
            if tx_done_i = '1' then st <= SEND_DEGN; end if;

          when SEND_DEGN =>
            if tx_busy_i = '0' then
              kick_send(std_logic_vector(to_unsigned(MAX_DEG, 8)));
              add_chk(std_logic_vector(to_unsigned(MAX_DEG, 8)));
              st <= WAIT_DEGN;
            end if;

          when WAIT_DEGN =>
            if tx_done_i = '1' then st <= SEND_M0; end if;

          -- mask bytes
          when SEND_M0 => if tx_busy_i='0' then kick_send(mask_arr(0)); add_chk(mask_arr(0)); st<=WAIT_M0; end if;
          when WAIT_M0 => if tx_done_i='1' then st<=SEND_M1; end if;

          when SEND_M1 => if tx_busy_i='0' then kick_send(mask_arr(1)); add_chk(mask_arr(1)); st<=WAIT_M1; end if;
          when WAIT_M1 => if tx_done_i='1' then st<=SEND_M2; end if;

          when SEND_M2 => if tx_busy_i='0' then kick_send(mask_arr(2)); add_chk(mask_arr(2)); st<=WAIT_M2; end if;
          when WAIT_M2 => if tx_done_i='1' then st<=SEND_M3; end if;

          when SEND_M3 => if tx_busy_i='0' then kick_send(mask_arr(3)); add_chk(mask_arr(3)); st<=WAIT_M3; end if;
          when WAIT_M3 => if tx_done_i='1' then st<=SEND_M4; end if;

          when SEND_M4 => if tx_busy_i='0' then kick_send(mask_arr(4)); add_chk(mask_arr(4)); st<=WAIT_M4; end if;
          when WAIT_M4 => if tx_done_i='1' then st<=SEND_M5; end if;

          when SEND_M5 => if tx_busy_i='0' then kick_send(mask_arr(5)); add_chk(mask_arr(5)); st<=WAIT_M5; end if;
          when WAIT_M5 => if tx_done_i='1' then st<=SEND_M6; end if;

          when SEND_M6 => if tx_busy_i='0' then kick_send(mask_arr(6)); add_chk(mask_arr(6)); st<=WAIT_M6; end if;
          when WAIT_M6 => if tx_done_i='1' then st<=SEND_M7; end if;

          when SEND_M7 => if tx_busy_i='0' then kick_send(mask_arr(7)); add_chk(mask_arr(7)); st<=WAIT_M7; end if;
          when WAIT_M7 => if tx_done_i='1' then st<=RD_NODE_SET; end if;

          -- ==========================
          -- nodes
          -- ==========================
          when RD_NODE_SET =>
            node_raddr_s <= node_idx;
            st <= RD_NODE_WAIT;

          when RD_NODE_WAIT =>
            st <= RD_NODE_LATCH;

          when RD_NODE_LATCH =>
            node_reg <= node_rdata_i;
            st <= SEND_N0;

          when SEND_N0 =>
            if tx_busy_i='0' then kick_send(node_reg(7 downto 0));  add_chk(node_reg(7 downto 0));  st<=WAIT_N0; end if;
          when WAIT_N0 => if tx_done_i='1' then st<=SEND_N1; end if;

          when SEND_N1 =>
            if tx_busy_i='0' then kick_send(node_reg(15 downto 8)); add_chk(node_reg(15 downto 8)); st<=WAIT_N1; end if;
          when WAIT_N1 => if tx_done_i='1' then st<=SEND_N2; end if;

          when SEND_N2 =>
            if tx_busy_i='0' then kick_send(node_reg(23 downto 16)); add_chk(node_reg(23 downto 16)); st<=WAIT_N2; end if;
          when WAIT_N2 => if tx_done_i='1' then st<=SEND_N3; end if;

          when SEND_N3 =>
            if tx_busy_i='0' then kick_send(node_reg(31 downto 24)); add_chk(node_reg(31 downto 24)); st<=WAIT_N3; end if;

          when WAIT_N3 =>
            if tx_done_i='1' then
              if node_idx = to_unsigned(MAX_NODES-1, node_idx'length) then
                edge_idx <= (others => '0');
                st <= RD_EDGE_SET;
              else
                node_idx <= node_idx + 1;
                st <= RD_NODE_SET;
              end if;
            end if;

          -- ==========================
          -- edges
          -- ==========================
          when RD_EDGE_SET =>
            edge_raddr_s <= edge_idx;
            st <= RD_EDGE_WAIT;

          when RD_EDGE_WAIT =>
            st <= RD_EDGE_LATCH;

          when RD_EDGE_LATCH =>
            edge_reg <= edge_rdata_i;
            st <= SEND_E0;

          when SEND_E0 =>
            if tx_busy_i='0' then kick_send(edge_reg(7 downto 0)); add_chk(edge_reg(7 downto 0)); st<=WAIT_E0; end if;
          when WAIT_E0 => if tx_done_i='1' then st<=SEND_E1; end if;

          when SEND_E1 =>
            if tx_busy_i='0' then kick_send(edge_reg(15 downto 8)); add_chk(edge_reg(15 downto 8)); st<=WAIT_E1; end if;

          when WAIT_E1 =>
            if tx_done_i='1' then
              if edge_idx = to_unsigned(EDGE_DEPTH-1, edge_idx'length) then
                st <= SEND_CHK;
              else
                edge_idx <= edge_idx + 1;
                st <= RD_EDGE_SET;
              end if;
            end if;

          -- ==========================
          -- checksum + finish (ONE-SHOT)
          -- ==========================
          when SEND_CHK =>
            if tx_busy_i='0' then
              kick_send(std_logic_vector(chk));
              st <= WAIT_CHK;
            end if;

          when WAIT_CHK =>
            if tx_done_i='1' then st <= FINISH; end if;

          when FINISH =>
            done_o <= '1';      -- SEND_DONE pulse 1 clk
            seq    <= seq + 1;  -- optional: nomor dump
            st     <= IDLE;     -- stop (tidak looping)

          when others =>
            st <= IDLE;

        end case;
      end if;
    end if;
  end process;

  busy_o <= '0' when (st = IDLE) else '1';

end architecture;
