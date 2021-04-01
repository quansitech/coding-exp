--
-- 表的结构 `kb_book_data`
--

CREATE TABLE `kb_book_data` (
  `id` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL,
  `isbn` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '',
  `book_name` varchar(190) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL DEFAULT '',
  `create_date` int NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;


--
-- 转存表中的数据 `kb_book_data`
--

INSERT INTO `kb_book_data` (`id`, `isbn`, `book_name`,`create_date`) VALUES
('000365f9-a2e3-b5ab-bc1e-3561e3ed52d9', '9787544809757', '儿童哲学智慧书：幸福，是什么？',1432656000),
('000f7305-a488-1fc0-5943-450faf502652', '9787020049448', '劳拉的秘密',1554945615),
('001900ad-2974-d932-4084-cb1e2adc05c2', '9787539177168', '小文我也要当妈妈',1554941521),
('00193100-8804-06d5-3729-9606737c8df2', '9787535349903', '冰原上的剑齿虎', 1554941302),
('001bf037-caf3-7c5d-5726-d0e4500037e5', '9787538579796', '宇宙旅行记', 1554931531),
('001c5744-7e94-fa8a-cc62-c5b1f7b7690c', '9787805937106', '影响孩子一生的101个经典童话.银色卷', 1554946217),
('001cba80-1592-6332-5c1c-206bbf6abe1c', '9787811099683', '壮美的奥运', 1554944151),
('0020e7e4-d1ad-48e2-f78a-c50d5a154685', '9787539747057', '学数学/启蒙教育小书坊',1554931687),
('0022cadc-d83d-1bf3-6354-d02b39160a55', '9787532259243', '三国故事（全4册）',1554938452),
('0023ab04-9b5e-d1a1-d074-72a32e4042d9', '9787534260513', '侠路相逢', 1432569600);

--
-- 触发器 `kb_book_data`
--
DELIMITER $$
CREATE TRIGGER `tri_book_data_update_after` AFTER UPDATE ON `kb_book_data` FOR EACH ROW BEGIN
    insert into kb_es_sync(`data_key`) values(new.id);
END
$$
DELIMITER ;
--
-- 转储表的索引
--

--
-- 表的索引 `kb_book_data`
--
ALTER TABLE `kb_book_data`
  ADD PRIMARY KEY (`id`);

--
-- 表的结构 `kb_es_sync`
--

CREATE TABLE `kb_es_sync` (
  `id` bigint UNSIGNED NOT NULL,
  `data_key` varchar(50) COLLATE utf8mb4_general_ci NOT NULL,
  `create_date` timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- 转储表的索引
--

--
-- 表的索引 `kb_es_sync`
--
ALTER TABLE `kb_es_sync`
  ADD PRIMARY KEY (`id`);

--
-- 在导出的表使用AUTO_INCREMENT
--

--
-- 使用表AUTO_INCREMENT `kb_es_sync`
--
ALTER TABLE `kb_es_sync`
  MODIFY `id` bigint UNSIGNED NOT NULL AUTO_INCREMENT;