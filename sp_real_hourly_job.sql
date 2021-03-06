DROP PROCEDURE IF EXISTS stock_sts_static_real_db.sp_real_hourly_job;
CREATE PROCEDURE stock_sts_static_real_db.sp_real_hourly_job()
proc_label2: BEGIN
  #declare variable
  DECLARE v_last_job_time,v_last_data_time,v_kor_data_time,v_kor_date  timestamp;
  DECLARE v_last_mat_no, v_max_mat_no int;
  DECLARE v_job_done_yn varchar(1);
  DECLARE v_job_yyyy, v_now_yyyy date;
  DECLARE v_job_hh,v_now_hh char(2);
  declare v_now_hour int;

  
   ## 실전투자가 수집이 끝나면 통합DB의 기존 데이터를 delete후 전체 재 수집을 한다 ## 
   ## last_data_time : 영업일자에 임의로 0시부터 23시까지 시간을 만들었는데 이 컬럼은 '영업일자와 시간'이 들어가 있는 컬럼.
    
   -- 1. 청산 작업 --
   
    # 마지막 작업시간 및 번호 확인
  SELECT last_job_time, last_data_time, last_mat_no, job_done_yn into  v_last_job_time, v_last_data_time, v_last_mat_no, v_job_done_yn
  FROM last_job_time order by last_data_time desc limit 1;


   ## job 실행되야할 날짜와 시간 저장. job의 최종 시간보다 1시간 뒤의 데이터를 찾는다.
  set v_job_yyyy=date(adddate(v_last_data_time, INTERVAL 1 HOUR));
  set v_job_hh=hour(adddate(v_last_data_time,interval 1 HOUR));
  set v_kor_data_time=adddate(v_last_data_time, INTERVAL 1 HOUR); -- 한국시간 계산을 위한 영업날짜시간 값.
  set v_now_yyyy=date(now());
  set v_now_hh=hour(now());
  
  select kor_date into v_kor_date from stock_sts_static_db.bsns_date_mat_tbl where bsns_date=v_kor_data_time;
  
if v_kor_date>=date_format(now(),'%Y-%m-%d %H:00:00') then
  LEAVE proc_label2;
end if; 

-- # 진입 청산 매칭 실행 

    call sp_real_cns(v_last_data_time);
    call sp_outer_loop_stl(v_last_mat_no);
    call sp_del_ent(v_job_yyyy,v_job_hh);
    
  
-- 최종거래일  -- 영업일 
    update stock_sts_static_db.trader_tot_tbl as target ,
              (select trader_no,date(max(ymd)) as min_cns from  stock_sts_static_real_db.cns_tbl where idx_no>v_max_mat_no group by trader_no ) as cns
    set target.last_trade_ymd=cns.min_cns
    where target.trader_no=cns.trader_no and  (target.last_trade_ymd<cns.min_cns or target.last_trade_ymd is null);


   # 청산매칭 테이블에서 '마지막 매칭번호' 이후의 번호와 청산일이 '마지막 데이터 시간'보다 +1시간 인 데이터 찾기. 
  select max(mat_no) into v_max_mat_no 
  from ent_stl_mat_tbl 
  where mat_no>v_last_mat_no and ymd=v_job_yyyy and bsns_time=v_job_hh;

  # 청산데이터가 있으면 실행  / 청산 관련 수집만.
  if v_max_mat_no is not null then

    ## 단위프로시저 호출
    call sp_hourly_trader_pro(v_job_yyyy,v_job_hh,v_last_mat_no); -- 청산기준으로 해야함.
    call sp_hourly_trader_patt(v_job_yyyy,v_job_hh,v_last_mat_no); -- 청산기준 
    call sp_hourly_trader_tot(v_job_yyyy,v_job_hh,v_last_mat_no); -- 
    call sp_hourly_pro(v_job_yyyy,v_job_hh,v_last_mat_no);
    call sp_hourly_trader_social(v_job_yyyy,v_job_hh,v_last_mat_no);  -- 

    INSERT INTO last_job_time
    (last_job_time, last_data_time, last_mat_no,  job_done_yn,last_kor_time) 
    VALUES (now(), adddate(v_last_data_time,INTERVAL 1 HOUR), v_max_mat_no, 'Y',v_kor_date);

 # 청산데이터가 없으면 청산작업은 완료  
  elseif v_max_mat_no is null then
    # 해당일자, 해당 시간에 데이터가 없으면 시간은 +1하고  job의 '매칭번호'를 기존의 번호로 저장한다.
    INSERT INTO last_job_time
    (last_job_time, last_data_time, last_mat_no, job_done_yn,last_kor_time) 
    VALUES (now(), adddate(v_last_data_time,INTERVAL 1 HOUR), v_last_mat_no, 'Y',v_kor_date);
  end if;


-- 2. 이 아래부터는 청산과 관련없이 체결테이블에서 직접 데이터를 가져온다.## 중요## 
-- 시간별 종목
INSERT INTO hourly_pro_tot_tbl(ymd,
                                    hh,
                                    pro_code,
                                    max_trade_qty,
                                    buy_cnt,
                                    sell_cnt,
                                    cp_trade_cnt,
                                    flw_trade_cnt,
                                    mna_trade_cnt,
                                    all_trade_cnt,
                                    all_trade_qty)
   SELECT ymd,
          bsns_time,
          pro.iem_gr,
          max(cns_qty),
          sum(CASE sby_cd WHEN '2' THEN 1 ELSE 0 END),                -- 매수 횟수
          sum(CASE sby_cd WHEN '1' THEN 1 ELSE 0 END),                -- 매도 횟수
          sum(CASE cpy_gb WHEN 'C' THEN 1 ELSE 0 END),              -- 카피 거래횟수
          sum(CASE cpy_gb WHEN 'F' THEN 1 ELSE 0 END),              -- 팔로 거래횟수
          sum(CASE cpy_gb WHEN 'M' THEN 1 ELSE 0 END),              -- 직접 거래횟수
          count(*) as cnt,                                          -- 전체 거래 횟수
          sum(cns_qty) as qty                                         -- 전체 거래 수량
     FROM cns_tbl AS ct
          INNER JOIN stock_sts_db.sts_sise_mast_tbl AS pro
             ON ct.iem_cd = pro.iem_cd
    WHERE ymd = v_job_yyyy AND bsns_time = v_job_hh
   GROUP BY ymd,bsns_time,pro.iem_gr
   ON DUPLICATE KEY UPDATE  
       max_trade_qty = values(max_trade_qty), buy_cnt = values(buy_cnt), sell_cnt = values(sell_cnt), 
       cp_trade_cnt = values(cp_trade_cnt), flw_trade_cnt = values(flw_trade_cnt), 
       mna_trade_cnt = values(mna_trade_cnt), all_trade_cnt = values(all_trade_cnt), all_trade_qty = values(all_trade_qty);

-- 시간별 트레이더 종합
INSERT INTO hourly_trader_tot_tbl(ymd,
                                       hh,
                                       trader_no,
                                       max_trade_qty,
                                       mna_trade_cnt,
                                       all_trade_cnt,
                                       all_trade_qty)
   SELECT ymd,
          bsns_time,
          trader_no,
          max(cns_qty),                                              -- 최대 주문량
          sum(CASE cpy_gb WHEN 'M' THEN 1 ELSE 0 END),             -- 직접 매매 횟수
          count(*),                                                 -- 전체 매매횟수
          sum(cns_qty)                                              -- 전체 매매수량
     FROM cns_tbl AS ct
    WHERE ymd = v_job_yyyy AND bsns_time = v_job_hh
   GROUP BY ymd, bsns_time, trader_no
   ON DUPLICATE KEY UPDATE 
       max_trade_qty=values(max_trade_qty),mna_trade_cnt=values(mna_trade_cnt),
       all_trade_cnt=values(all_trade_cnt),all_trade_qty=values(all_trade_qty);
       
   
-- 소셜 시간별 집계  

# 내가 트레이더 인 경우
insert into hourly_trader_social_tbl(ymd,
                                     hh,
                                     trader_no,
                                     cpr_trade_cnt,
                                     cpr_qty_cnt,
                                     flwr_trade_cnt,
                                     flwr_qty_cnt)                                    
   SELECT ymd,
          bsns_time,
          ldr_trader_no,
          sum(case cpy_gb when 'C' then 1 else 0 end), -- 나를 카피한 사람수
          sum(case cpy_gb when 'C' then cns_qty else 0 end), -- 카피어 매매수량
          sum(case cpy_gb when 'F' then 1 else 0 end), -- 나를 팔로우한 사람수
          sum(case cpy_gb when 'F' then cns_qty else 0 end) -- 팔로어 매매수량 
     from cns_tbl
    WHERE ymd=v_job_yyyy and bsns_time=v_job_hh and ldr_trader_no>0
   GROUP BY ymd,bsns_time,ldr_trader_no
   ON DUPLICATE KEY UPDATE 
      cpr_trade_cnt=values(cpr_trade_cnt),cpr_qty_cnt=values(cpr_qty_cnt),
      flwr_trade_cnt=values(flwr_trade_cnt),flwr_qty_cnt=values(flwr_qty_cnt);
   
            
# 내가 누굴 따르는 경우             
insert into hourly_trader_social_tbl(ymd,
                                     hh,
                                     trader_no,
                                     cp_trade_cnt,
                                     cp_qty_cnt,
                                     flw_trade_cnt,
                                     flw_qty_cnt)
   SELECT ymd,
          bsns_time,
          trader_no,
          sum(CASE cpy_gb WHEN 'C' THEN 1 ELSE 0 END),           -- 카피잉 매매횟수 
          sum(case cpy_gb when 'C' then cns_qty else 0 end), -- 카피잉 매매수량
          sum(CASE cpy_gb WHEN 'F' THEN 1 ELSE 0 END),           -- 팔로잉 매매횟수 
          sum(case cpy_gb when 'F' then cns_qty else 0 end)  -- 팔로잉 수량 
     from cns_tbl
    WHERE ymd=v_job_yyyy and bsns_time=v_job_hh and ldr_trader_no>0
   GROUP BY ymd, bsns_time, trader_no
   ON DUPLICATE KEY UPDATE  cp_trade_cnt=values(cp_trade_cnt), cp_qty_cnt=values(cp_qty_cnt) ,
                           flw_trade_cnt=values(flw_trade_cnt),flw_qty_cnt=values(flw_qty_cnt);   
 
   
  -- ### 카피와 팔로우 관계 테이블. duplicate가 안되므로 당일 전체 집계 
  delete from daily_copy_trade_tot where  ymd=v_job_yyyy;
            -- 체결테이블에서 전체 거래횟수를 가져온다.
  INSERT INTO daily_copy_trade_tot
  (trader_no, copier_no, ymd, trade_cnt) 
  select ldr_trader_no, trader_no,ymd, count(*)
  from cns_tbl 
  where ldr_trader_no>0 and cpy_gb='C' and  ymd=v_job_yyyy 
  group by ymd,trader_no,ldr_trader_no;
            -- 청산매칭테이블에서 수익률과 수익금 가져온다.
  UPDATE daily_copy_trade_tot AS tar,
         (SELECT ymd,
                 ldr_trader_no,
                 trader_no,
                 sum(prf_rate) AS sumra,
                 sum(pls_amt) AS sumpl
            FROM ent_stl_mat_tbl
           WHERE ldr_trader_no > 0 AND cpy_gb = 'C' AND ymd = v_job_yyyy
          GROUP BY ymd, trader_no, ldr_trader_no) AS mat
     SET tar.pls_amt = sumpl, tar.prt_rate = sumra
   WHERE     tar.ymd = mat.ymd
         AND tar.trader_no = ldr_trader_no
         AND tar.copier_no = mat.trader_no;
       
       -- 팔로잉 관계
  delete from daily_follow_trade_tot where  ymd=v_job_yyyy;
  
        -- 체결테이블에서 전체거래횟수를 가져온다.
  INSERT INTO daily_follow_trade_tot
  (trader_no, follower_no, ymd, trade_cnt) 
  select ldr_trader_no,trader_no,ymd,count(*)
  from cns_tbl 
  where ldr_trader_no>0 and cpy_gb='F' and  ymd=v_job_yyyy  
  group by ymd,trader_no,ldr_trader_no;
         -- 청산매칭 테이블에서 수익률과 수익금을 가져온다.
  UPDATE daily_follow_trade_tot AS tar,
         (SELECT ymd,
                 ldr_trader_no,
                 trader_no,
                 sum(prf_rate) AS sumra,
                 sum(pls_amt) AS sumpl
            FROM ent_stl_mat_tbl
           WHERE ldr_trader_no > 0 AND cpy_gb = 'F' AND ymd = v_job_yyyy
          GROUP BY ymd, trader_no, ldr_trader_no) AS mat
     SET tar.pls_amt = sumpl, tar.prt_rate = sumra
   WHERE     tar.ymd = mat.ymd
         AND tar.trader_no = ldr_trader_no
         AND tar.follower_no = mat.trader_no;

   
 -- 체결테이블에서 전체 가져오기 update. / 위에서 체결테이블로 시간별 테이블에 update를 했으므로 일자별 데이터 프로시저 호출을 한다.
    call sp_hourly_trader_time(v_kor_data_time,v_job_yyyy);
    call sp_daily_pro(v_job_yyyy,v_job_hh);
    call sp_daily_trader_tot(v_job_yyyy,v_job_hh);
    call sp_daily_trader_social(v_job_yyyy,v_job_hh); 
    call sp_hourly_real_trade_tot(v_job_yyyy,v_job_hh); -- 어드민용
  
 -- ### 3. 통합DB 수집 작업 -- 해당일자를 전체 삭제한다.
    -- call stock_sts_static_db.sp_daily_pls(v_job_yyyy);
    call stock_sts_static_db.sp_total_static(v_job_yyyy);
    call stock_sts_static_db.sp_period_static(v_job_yyyy); 


-- job이 23시에 실행되는 거면 미리 주간/월간 테이블을 생성한다. 23시에 실행되는것은 22시간의 데이터를 가지고 작업하므로 데이터 시간이 22시간이면 그다음날 걸 생성--
set v_now_hour=v_job_hh;

  if v_now_hour=22 then 
    call stock_sts_static_db.sp_period_static(date(date_add(v_last_data_time, interval 1 day)));
  end if;

END;