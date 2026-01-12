library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gng_snapshot40 is
  generic (
    NMAX    : natural := 40;
    XY_BITS : natural := 16
  );
  port (
    clk_i          : in  std_logic;
    rstn_i         : in  std_logic;

    sample_x_i     : in  signed(XY_BITS-1 downto 0);
    sample_y_i     : in  signed(XY_BITS-1 downto 0);
    sample_valid_i : in  std_logic;
    sample_ready_o : out std_logic;

    snap_i         : in  std_logic; -- 1-cycle pulse
    busy_o         : out std_logic;

    tx_ready_i     : in  std_logic;
    tx_valid_o     : out std_logic;
    tx_data_o      : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of gng_snapshot40 is

  constant CMD_NODES : std_logic_vector(7 downto 0) := x"10";
  constant CMD_EDGES : std_logic_vector(7 downto 0) := x"11";

  type xy_arr_t is array(0 to NMAX-1) of signed(XY_BITS-1 downto 0);
  signal x_mem : xy_arr_t := (others => (others => '0'));
  signal y_mem : xy_arr_t := (others => (others => '0'));

  signal store_cnt : unsigned(5 downto 0) := (others => '0'); -- 0..40

  type st_t is (
    IDLE,
    -- nodes
    N_H1, N_H2, N_CMD, N_LEN, N_FID, N_CNT,
    N_IDX, N_XL, N_XH, N_YL, N_YH,
    N_CHK,
    -- edges
    E_H1, E_H2, E_CMD, E_LEN, E_FID, E_CNT,
    E_A, E_B,
    E_CHK
  );
  signal st : st_t := IDLE;

  signal tx_valid_r : std_logic := '0';
  signal tx_data_r  : std_logic_vector(7 downto 0) := (others => '0');
  signal sum_u8     : unsigned(7 downto 0) := (others => '0');

  signal frame_id   : unsigned(7 downto 0) := (others => '0');

  signal node_cnt_r : unsigned(7 downto 0) := (others => '0');
  signal edge_cnt_r : unsigned(7 downto 0) := (others => '0');
  signal node_len_r : unsigned(7 downto 0) := (others => '0');
  signal edge_len_r : unsigned(7 downto 0) := (others => '0');

  signal node_idx   : unsigned(5 downto 0) := (others => '0');
  signal edge_idx   : unsigned(5 downto 0) := (others => '0');

  function lo8(s : signed(XY_BITS-1 downto 0)) return std_logic_vector is
  begin
    return std_logic_vector(s(7 downto 0));
  end function;

  function hi8(s : signed(XY_BITS-1 downto 0)) return std_logic_vector is
  begin
    return std_logic_vector(s(15 downto 8));
  end function;

begin

  tx_valid_o <= tx_valid_r;
  tx_data_o  <= tx_data_r;

  sample_ready_o <= '1' when st = IDLE else '0';
  busy_o         <= '0' when st = IDLE else '1';

  -- store first 40 samples
  process(clk_i)
    variable ii : integer;
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        store_cnt <= (others => '0');
      else
        if st = IDLE then
          if sample_valid_i = '1' then
            if store_cnt < to_unsigned(NMAX, store_cnt'length) then
              ii := to_integer(store_cnt);
              x_mem(ii) <= sample_x_i;
              y_mem(ii) <= sample_y_i;
              store_cnt <= store_cnt + 1;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- snapshot TX FSM
  process(clk_i)
    variable nc_i : integer;
    variable ec_i : integer;
    variable b_u  : unsigned(7 downto 0);
    variable xi   : integer;
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        st         <= IDLE;
        tx_valid_r <= '0';
        tx_data_r  <= (others => '0');
        sum_u8     <= (others => '0');
        frame_id   <= (others => '0');
        node_cnt_r <= (others => '0');
        edge_cnt_r <= (others => '0');
        node_len_r <= (others => '0');
        edge_len_r <= (others => '0');
        node_idx   <= (others => '0');
        edge_idx   <= (others => '0');
      else

        if (tx_valid_r = '1') and (tx_ready_i = '1') then
          tx_valid_r <= '0';
        end if;

        case st is
          when IDLE =>
            if snap_i = '1' then
              nc_i := to_integer(store_cnt);
              if nc_i > NMAX then nc_i := NMAX; end if;
              ec_i := nc_i - 1;
              if ec_i < 0 then ec_i := 0; end if;

              node_cnt_r <= to_unsigned(nc_i, 8);
              edge_cnt_r <= to_unsigned(ec_i, 8);

              node_len_r <= to_unsigned(2 + nc_i*5, 8);
              edge_len_r <= to_unsigned(2 + ec_i*2, 8);

              frame_id   <= frame_id + 1;
              node_idx   <= (others => '0');
              edge_idx   <= (others => '0');

              st <= N_H1;
            end if;

          -- ===== NODES frame =====
          when N_H1 =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= x"FF"; tx_valid_r <= '1';
              st <= N_H2;
            end if;

          when N_H2 =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= x"FF"; tx_valid_r <= '1';
              st <= N_CMD;
            end if;

          when N_CMD =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= CMD_NODES; tx_valid_r <= '1';
              sum_u8    <= unsigned(CMD_NODES);
              st <= N_LEN;
            end if;

          when N_LEN =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= std_logic_vector(node_len_r); tx_valid_r <= '1';
              sum_u8    <= sum_u8 + node_len_r;
              st <= N_FID;
            end if;

          when N_FID =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= std_logic_vector(frame_id); tx_valid_r <= '1';
              sum_u8    <= sum_u8 + frame_id;
              st <= N_CNT;
            end if;

          when N_CNT =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= std_logic_vector(node_cnt_r); tx_valid_r <= '1';
              sum_u8    <= sum_u8 + node_cnt_r;
              node_idx  <= (others => '0');
              if node_cnt_r = 0 then st <= N_CHK; else st <= N_IDX; end if;
            end if;

          when N_IDX =>
            if tx_valid_r='0' and tx_ready_i='1' then
              b_u := to_unsigned(to_integer(node_idx), 8);
              tx_data_r <= std_logic_vector(b_u); tx_valid_r <= '1';
              sum_u8    <= sum_u8 + b_u;
              st <= N_XL;
            end if;

          when N_XL =>
            if tx_valid_r='0' and tx_ready_i='1' then
              xi := to_integer(node_idx);
              tx_data_r <= lo8(x_mem(xi)); tx_valid_r <= '1';
              sum_u8    <= sum_u8 + unsigned(lo8(x_mem(xi)));
              st <= N_XH;
            end if;

          when N_XH =>
            if tx_valid_r='0' and tx_ready_i='1' then
              xi := to_integer(node_idx);
              tx_data_r <= hi8(x_mem(xi)); tx_valid_r <= '1';
              sum_u8    <= sum_u8 + unsigned(hi8(x_mem(xi)));
              st <= N_YL;
            end if;

          when N_YL =>
            if tx_valid_r='0' and tx_ready_i='1' then
              xi := to_integer(node_idx);
              tx_data_r <= lo8(y_mem(xi)); tx_valid_r <= '1';
              sum_u8    <= sum_u8 + unsigned(lo8(y_mem(xi)));
              st <= N_YH;
            end if;

          when N_YH =>
            if tx_valid_r='0' and tx_ready_i='1' then
              xi := to_integer(node_idx);
              tx_data_r <= hi8(y_mem(xi)); tx_valid_r <= '1';
              sum_u8    <= sum_u8 + unsigned(hi8(y_mem(xi)));

              if node_idx = to_unsigned(to_integer(node_cnt_r)-1, node_idx'length) then
                st <= N_CHK;
              else
                node_idx <= node_idx + 1;
                st <= N_IDX;
              end if;
            end if;

          when N_CHK =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= std_logic_vector(not sum_u8); tx_valid_r <= '1';
              st <= E_H1;
            end if;

          -- ===== EDGES frame =====
          when E_H1 =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= x"FF"; tx_valid_r <= '1';
              st <= E_H2;
            end if;

          when E_H2 =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= x"FF"; tx_valid_r <= '1';
              st <= E_CMD;
            end if;

          when E_CMD =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= CMD_EDGES; tx_valid_r <= '1';
              sum_u8    <= unsigned(CMD_EDGES);
              st <= E_LEN;
            end if;

          when E_LEN =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= std_logic_vector(edge_len_r); tx_valid_r <= '1';
              sum_u8    <= sum_u8 + edge_len_r;
              st <= E_FID;
            end if;

          when E_FID =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= std_logic_vector(frame_id); tx_valid_r <= '1';
              sum_u8    <= sum_u8 + frame_id;
              st <= E_CNT;
            end if;

          when E_CNT =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= std_logic_vector(edge_cnt_r); tx_valid_r <= '1';
              sum_u8    <= sum_u8 + edge_cnt_r;
              edge_idx  <= (others => '0');
              if edge_cnt_r = 0 then st <= E_CHK; else st <= E_A; end if;
            end if;

          when E_A =>
            if tx_valid_r='0' and tx_ready_i='1' then
              b_u := to_unsigned(to_integer(edge_idx), 8);
              tx_data_r <= std_logic_vector(b_u); tx_valid_r <= '1';
              sum_u8    <= sum_u8 + b_u;
              st <= E_B;
            end if;

          when E_B =>
            if tx_valid_r='0' and tx_ready_i='1' then
              b_u := to_unsigned(to_integer(edge_idx)+1, 8);
              tx_data_r <= std_logic_vector(b_u); tx_valid_r <= '1';
              sum_u8    <= sum_u8 + b_u;

              if edge_idx = to_unsigned(to_integer(edge_cnt_r)-1, edge_idx'length) then
                st <= E_CHK;
              else
                edge_idx <= edge_idx + 1;
                st <= E_A;
              end if;
            end if;

          when E_CHK =>
            if tx_valid_r='0' and tx_ready_i='1' then
              tx_data_r <= std_logic_vector(not sum_u8); tx_valid_r <= '1';
              st <= IDLE;
            end if;

          when others =>
            st <= IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture;
