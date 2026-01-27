library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng_dump_nodes_winners_uart is
  generic (
    MAX_NODES  : natural := 40;
    MASK_BYTES : natural := 8;   -- set = (MAX_NODES+7)/8
    N_SAMPLES  : natural := 100
  );
  port (
    clk_i  : in  std_logic;
    rstn_i : in  std_logic;

    start_i : in std_logic;

    -- node/err (sync 1-cycle read)
    node_raddr_o : out unsigned(7 downto 0);
    node_rdata_i : in  std_logic_vector(31 downto 0);

    err_raddr_o  : out unsigned(7 downto 0);
    err_rdata_i  : in  std_logic_vector(31 downto 0);

    -- winner log (sync 1-cycle read)
    win_raddr_o : out unsigned(6 downto 0);
    win_rdata_i : in  std_logic_vector(15 downto 0); -- [7:0]=s1, [15:8]=s2

    step_i : in unsigned(15 downto 0) := (others => '0');

    -- UART TX handshake
    tx_busy_i  : in  std_logic;
    tx_done_i  : in  std_logic;
    tx_start_o : out std_logic;
    tx_data_o  : out std_logic_vector(7 downto 0);

    done_o : out std_logic;  -- pulse 1 clk
    busy_o : out std_logic
  );
end entity;

architecture rtl of gng_dump_nodes_winners_uart is

  constant A1_PAYLOAD_BYTES : natural := 1 + 2 + 1 + 1 + MASK_BYTES + (MAX_NODES * 4);
  constant B1_PAYLOAD_BYTES : natural := 1 + 1 + (N_SAMPLES * 3);

  type mask_arr_t is array (0 to MASK_BYTES-1) of std_logic_vector(7 downto 0);
  signal mask_arr : mask_arr_t := (others => (others => '0'));

  type st_t is (
    IDLE,

    -- build mask from err_mem
    MCLR, M_RD_SET, M_RD_WAIT, M_RD_LATCH,

    -- send packet 0xA1
    A1_FF1, A1_WFF1, A1_FF2, A1_WFF2,
    A1_LEN0, A1_WLEN0, A1_LEN1, A1_WLEN1,
    A1_SEQ,  A1_WSEQ,
    A1_TYPE, A1_WTYPE,
    A1_STEP0, A1_WSTEP0,
    A1_STEP1, A1_WSTEP1,
    A1_NN,   A1_WNN,
    A1_DN,   A1_WDN,
    A1_MASK, A1_WMASK,
    A1_NR_SET, A1_NR_WAIT, A1_NR_LATCH,
    A1_XL, A1_WXL, A1_XH, A1_WXH, A1_YL, A1_WYL, A1_YH, A1_WYH,
    A1_CHK, A1_WCHK,

    -- send packet 0xB1
    B1_FF1, B1_WFF1, B1_FF2, B1_WFF2,
    B1_LEN0, B1_WLEN0, B1_LEN1, B1_WLEN1,
    B1_SEQ,  B1_WSEQ,
    B1_TYPE, B1_WTYPE,
    B1_N,    B1_WN,
    B1_RD_SET, B1_RD_WAIT, B1_RD_LATCH,
    B1_IDX, B1_WIDX, B1_S1, B1_WS1, B1_S2, B1_WS2,
    B1_CHK, B1_WCHK,

    FINISH
  );

  signal st  : st_t := IDLE;

  signal seq : unsigned(7 downto 0) := (others => '0');
  signal chk : unsigned(7 downto 0) := (others => '0');

  signal start_d : std_logic := '0';
  signal start_p : std_logic := '0';

  signal mi     : unsigned(7 downto 0) := (others => '0');
  signal mask_k : integer range 0 to MASK_BYTES-1 := 0;

  signal nid    : unsigned(7 downto 0) := (others => '0');
  signal node_reg : std_logic_vector(31 downto 0) := (others => '0');

  signal idx     : unsigned(6 downto 0) := (others => '0');
  signal win_reg : std_logic_vector(15 downto 0) := (others => '0');

  function lo8(v : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(v,16)(7 downto 0));
  end function;

  function hi8(v : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(v,16)(15 downto 8));
  end function;

begin

  -- start edge detect
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        start_d <= '0';
        start_p <= '0';
      else
        start_p <= start_i and (not start_d);
        start_d <= start_i;
      end if;
    end if;
  end process;

  process(clk_i)
    procedure kick(b : std_logic_vector(7 downto 0)) is
    begin
      tx_data_o  <= b;
      tx_start_o <= '1';
    end procedure;

    procedure add(b : std_logic_vector(7 downto 0)) is
    begin
      chk <= chk + unsigned(b);
    end procedure;

    variable byte_idx : integer;
    variable bit_idx  : integer;
    variable tmp      : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk_i) then
      tx_start_o <= '0';
      done_o     <= '0';

      if rstn_i = '0' then
        st <= IDLE;
        seq <= (others => '0');
        chk <= (others => '0');

        node_raddr_o <= (others => '0');
        err_raddr_o  <= (others => '0');
        win_raddr_o  <= (others => '0');

        mi  <= (others => '0');
        nid <= (others => '0');
        idx <= (others => '0');

        mask_k <= 0;
        mask_arr <= (others => (others => '0'));

      else
        case st is

          when IDLE =>
            if start_p = '1' then
              st <= MCLR;
            end if;

          -- build mask
          when MCLR =>
            mask_arr <= (others => (others => '0'));
            mi <= (others => '0');
            st <= M_RD_SET;

          when M_RD_SET =>
            err_raddr_o <= mi;
            st <= M_RD_WAIT;

          when M_RD_WAIT =>
            st <= M_RD_LATCH;

          when M_RD_LATCH =>
            if err_rdata_i(31) = '1' then
              byte_idx := to_integer(mi(7 downto 3));
              bit_idx  := to_integer(mi(2 downto 0));
              if (byte_idx >= 0) and (byte_idx < MASK_BYTES) then
                tmp := mask_arr(byte_idx);
                tmp(bit_idx) := '1';
                mask_arr(byte_idx) <= tmp;
              end if;
            end if;

            if mi = to_unsigned(MAX_NODES-1, mi'length) then
              st <= A1_FF1;
            else
              mi <= mi + 1;
              st <= M_RD_SET;
            end if;

          -- Packet 0xA1
          when A1_FF1 =>
            if tx_busy_i='0' then kick(x"FF"); st<=A1_WFF1; end if;
          when A1_WFF1 =>
            if tx_done_i='1' then st<=A1_FF2; end if;

          when A1_FF2 =>
            if tx_busy_i='0' then kick(x"FF"); st<=A1_WFF2; end if;
          when A1_WFF2 =>
            if tx_done_i='1' then st<=A1_LEN0; end if;

          when A1_LEN0 =>
            if tx_busy_i='0' then kick(lo8(A1_PAYLOAD_BYTES)); st<=A1_WLEN0; end if;
          when A1_WLEN0 =>
            if tx_done_i='1' then st<=A1_LEN1; end if;

          when A1_LEN1 =>
            if tx_busy_i='0' then kick(hi8(A1_PAYLOAD_BYTES)); st<=A1_WLEN1; end if;
          when A1_WLEN1 =>
            if tx_done_i='1' then st<=A1_SEQ; end if;

          when A1_SEQ =>
            if tx_busy_i='0' then
              kick(std_logic_vector(seq));
              chk <= (others=>'0');
              mask_k <= 0;
              nid <= (others => '0');
              st <= A1_WSEQ;
            end if;
          when A1_WSEQ =>
            if tx_done_i='1' then st<=A1_TYPE; end if;

          when A1_TYPE =>
            if tx_busy_i='0' then
              kick(x"A1"); add(x"A1");
              st <= A1_WTYPE;
            end if;
          when A1_WTYPE =>
            if tx_done_i='1' then st<=A1_STEP0; end if;

          when A1_STEP0 =>
            if tx_busy_i='0' then
              kick(std_logic_vector(step_i(7 downto 0))); add(std_logic_vector(step_i(7 downto 0)));
              st <= A1_WSTEP0;
            end if;
          when A1_WSTEP0 =>
            if tx_done_i='1' then st<=A1_STEP1; end if;

          when A1_STEP1 =>
            if tx_busy_i='0' then
              kick(std_logic_vector(step_i(15 downto 8))); add(std_logic_vector(step_i(15 downto 8)));
              st <= A1_WSTEP1;
            end if;
          when A1_WSTEP1 =>
            if tx_done_i='1' then st<=A1_NN; end if;

          when A1_NN =>
            if tx_busy_i='0' then
              kick(std_logic_vector(to_unsigned(MAX_NODES,8)));
              add(std_logic_vector(to_unsigned(MAX_NODES,8)));
              st <= A1_WNN;
            end if;
          when A1_WNN =>
            if tx_done_i='1' then st<=A1_DN; end if;

          when A1_DN =>
            if tx_busy_i='0' then
              kick(x"00"); add(x"00"); -- degN=0 (no edges in this dumper)
              st <= A1_WDN;
            end if;
          when A1_WDN =>
            if tx_done_i='1' then st<=A1_MASK; end if;

          when A1_MASK =>
            if tx_busy_i='0' then
              kick(mask_arr(mask_k));
              add(mask_arr(mask_k));
              st <= A1_WMASK;
            end if;
          when A1_WMASK =>
            if tx_done_i='1' then
              if mask_k = MASK_BYTES-1 then
                st <= A1_NR_SET;
              else
                mask_k <= mask_k + 1;
                st <= A1_MASK;
              end if;
            end if;

          -- nodes stream
          when A1_NR_SET =>
            node_raddr_o <= nid;
            st <= A1_NR_WAIT;

          when A1_NR_WAIT =>
            st <= A1_NR_LATCH;

          when A1_NR_LATCH =>
            node_reg <= node_rdata_i;
            st <= A1_XL;

          when A1_XL =>
            if tx_busy_i='0' then
              kick(node_reg(7 downto 0)); add(node_reg(7 downto 0));
              st <= A1_WXL;
            end if;
          when A1_WXL =>
            if tx_done_i='1' then st<=A1_XH; end if;

          when A1_XH =>
            if tx_busy_i='0' then
              kick(node_reg(15 downto 8)); add(node_reg(15 downto 8));
              st <= A1_WXH;
            end if;
          when A1_WXH =>
            if tx_done_i='1' then st<=A1_YL; end if;

          when A1_YL =>
            if tx_busy_i='0' then
              kick(node_reg(23 downto 16)); add(node_reg(23 downto 16));
              st <= A1_WYL;
            end if;
          when A1_WYL =>
            if tx_done_i='1' then st<=A1_YH; end if;

          when A1_YH =>
            if tx_busy_i='0' then
              kick(node_reg(31 downto 24)); add(node_reg(31 downto 24));
              st <= A1_WYH;
            end if;
          when A1_WYH =>
            if tx_done_i='1' then
              if nid = to_unsigned(MAX_NODES-1, nid'length) then
                st <= A1_CHK;
              else
                nid <= nid + 1;
                st <= A1_NR_SET;
              end if;
            end if;

          when A1_CHK =>
            if tx_busy_i='0' then
              kick(std_logic_vector(chk));
              st <= A1_WCHK;
            end if;
          when A1_WCHK =>
            if tx_done_i='1' then
              seq <= seq + 1;
              st  <= B1_FF1;
            end if;

          -- Packet 0xB1 winners
          when B1_FF1 =>
            if tx_busy_i='0' then kick(x"FF"); st<=B1_WFF1; end if;
          when B1_WFF1 =>
            if tx_done_i='1' then st<=B1_FF2; end if;

          when B1_FF2 =>
            if tx_busy_i='0' then kick(x"FF"); st<=B1_WFF2; end if;
          when B1_WFF2 =>
            if tx_done_i='1' then st<=B1_LEN0; end if;

          when B1_LEN0 =>
            if tx_busy_i='0' then kick(lo8(B1_PAYLOAD_BYTES)); st<=B1_WLEN0; end if;
          when B1_WLEN0 =>
            if tx_done_i='1' then st<=B1_LEN1; end if;

          when B1_LEN1 =>
            if tx_busy_i='0' then kick(hi8(B1_PAYLOAD_BYTES)); st<=B1_WLEN1; end if;
          when B1_WLEN1 =>
            if tx_done_i='1' then st<=B1_SEQ; end if;

          when B1_SEQ =>
            if tx_busy_i='0' then
              kick(std_logic_vector(seq));
              chk <= (others=>'0');
              idx <= (others=>'0');
              st <= B1_WSEQ;
            end if;
          when B1_WSEQ =>
            if tx_done_i='1' then st<=B1_TYPE; end if;

          when B1_TYPE =>
            if tx_busy_i='0' then
              kick(x"B1"); add(x"B1");
              st <= B1_WTYPE;
            end if;
          when B1_WTYPE =>
            if tx_done_i='1' then st<=B1_N; end if;

          when B1_N =>
            if tx_busy_i='0' then
              kick(std_logic_vector(to_unsigned(N_SAMPLES,8)));
              add(std_logic_vector(to_unsigned(N_SAMPLES,8)));
              st <= B1_WN;
            end if;
          when B1_WN =>
            if tx_done_i='1' then st<=B1_RD_SET; end if;

          when B1_RD_SET =>
            win_raddr_o <= idx;
            st <= B1_RD_WAIT;

          when B1_RD_WAIT =>
            st <= B1_RD_LATCH;

          when B1_RD_LATCH =>
            win_reg <= win_rdata_i;
            st <= B1_IDX;

          when B1_IDX =>
            if tx_busy_i='0' then
              kick(std_logic_vector(resize(idx,8)));
              add(std_logic_vector(resize(idx,8)));
              st <= B1_WIDX;
            end if;
          when B1_WIDX =>
            if tx_done_i='1' then st<=B1_S1; end if;

          when B1_S1 =>
            if tx_busy_i='0' then
              kick(win_reg(7 downto 0)); add(win_reg(7 downto 0));
              st <= B1_WS1;
            end if;
          when B1_WS1 =>
            if tx_done_i='1' then st<=B1_S2; end if;

          when B1_S2 =>
            if tx_busy_i='0' then
              kick(win_reg(15 downto 8)); add(win_reg(15 downto 8));
              st <= B1_WS2;
            end if;
          when B1_WS2 =>
            if tx_done_i='1' then
              if idx = to_unsigned(N_SAMPLES-1, idx'length) then
                st <= B1_CHK;
              else
                idx <= idx + 1;
                st  <= B1_RD_SET;
              end if;
            end if;

          when B1_CHK =>
            if tx_busy_i='0' then
              kick(std_logic_vector(chk));
              st <= B1_WCHK;
            end if;
          when B1_WCHK =>
            if tx_done_i='1' then
              seq <= seq + 1;
              st  <= FINISH;
            end if;

          when FINISH =>
            done_o <= '1';
            st <= IDLE;

          when others =>
            st <= IDLE;

        end case;
      end if;
    end if;
  end process;

  busy_o <= '0' when st = IDLE else '1';

end architecture;
